unit Mundus.Renderer;

interface

uses
  Types,
  Classes,
  Windows,
  SysUtils,
  Graphics,
  Generics.Collections,
  Mundus.Math,
  Mundus.Mesh,
  Mundus.Types,
  Mundus.Shader,
  Mundus.Diagnostics.StopWatch,
  Mundus.DrawCall,
  Mundus.Renderer.Worker,
  Mundus.Camera,
  Mundus.ValueBuffer;

type
  TRenderEvent = procedure(Canvas: TCanvas) of object;
  TInitBufferEvent = reference to procedure(AMesh: TMesh; const ABuffer: PValueBuffers);

  TMundusRenderer = class
  private
    FDepthBuffer: array[boolean] of TDepthBuffer;
    FBackBuffer: array[boolean] of TBitmap;
    FDrawCalls: array[boolean] of TDrawCalls;
    FMeshList: TObjectList<TMesh>;
    FFPS: Integer;
    FLineLength: NativeInt;
    FFirstLine: PRGB32Array;
    FResolutionX: Integer;
    FResolutionY: Integer;
    FOnAfterFrame: TRenderEvent;
    FTimer: TStopWatch;
    FWorkers: TObjectList<TRenderWorker>;
    FRenderFences: TArray<THandle>;
    FCurrentBuffer: Boolean;
    FWorkerFPS: Integer;
    FCamera: TCamera;
    FOnInitValueBuffer: TInitBufferEvent;
    procedure SetDepthBufferSize(ABuffer: Boolean; AWidth, AHeight: Integer);
    procedure ClearDepthBuffer(ABuffer: Boolean);
    procedure TransformMesh(AMesh: TMesh; AWorld, AProjection: TMatrix4x4; ATargetCall: PDrawCall);
    procedure DoAfterFrame(ACanvas: TCanvas);
    function GenerateDrawCalls(const AViewMatrix: TMatrix4x4): TDrawCalls;
    procedure DispatchCalls(ACanvas: TCanvas; ACalls: TDrawCalls);
    procedure SpinupWorkers(AWorkerCount: Integer);
    procedure TerminateWorkers;
    procedure WaitForRender;
    procedure UpdateBufferResolution(ABuffer: Boolean; AWidth, AHeight: Integer);
    procedure ClearBuffer(ABuffer: Boolean);
    function GetRenderWorkers: Integer;
  public
    constructor Create(AWorker: Integer = 1);
    destructor Destroy(); override;
    procedure SetResolution(AWidth, AHeight: Integer);
    procedure RenderFrame(ACanvas: TCanvas);
    function GetCurrentFPS(): Integer;
    property MeshList: TObjectList<TMesh> read FMeshList;
    property OnAfterFrame: TRenderEvent read FOnAfterFrame write FOnAfterFrame;
    property ResolutionX: Integer read FResolutionX;
    property ResolutionY: Integer read FResolutionY;
    property Camera: TCamera read FCamera;
    property ReenderWorkers: Integer read GetRenderWorkers;
    property OnInitValueBuffer: TInitBufferEvent read FOnInitValueBuffer write FOnInitValueBuffer;
  end;

  function RGB32(ARed, AGreen, ABlue, AAlpha: Byte): TRGB32;

implementation

uses
  Math,
  DateUtils,
  Mundus.Shader.VertexGradient,
  Mundus.Shader.DepthColor,
  Mundus.Shader.Texture,
  Mundus.Rasterizer,
  Mundus.Renderer.Clipping;

{ TSoftwareRenderer }

procedure TMundusRenderer.ClearBuffer(ABuffer: Boolean);
var
  LBuffer: TBitmap;
  LFirstLine: PByte;
  LBufferLength: NativeInt;
begin
  LBuffer := FBackBuffer[ABuffer];
  LFirstLine := LBuffer.ScanLine[LBuffer.Height-1];
  LBufferLength := (NativeInt(LBuffer.Scanline[0]) - NativeInt(LFirstLine)) + LBuffer.Width * SizeOf(TRGB32);
  ZeroMemory(LFirstLine, LBufferLength);
end;

procedure TMundusRenderer.ClearDepthBuffer;
var
  LBytes: Integer;
  LBuffer: TDepthBuffer;
begin
  LBuffer := FDepthBuffer[ABuffer];
  LBytes := Length(LBuffer) * SizeOf(Single);
  ZeroMemory(@LBuffer[0], LBytes);
end;

constructor TMundusRenderer.Create;
begin
  FBackBuffer[True] := TBitmap.Create();
  FBackbuffer[True].PixelFormat := pf32bit;
  FBackBuffer[False] := TBitmap.Create();
  FBackbuffer[False].PixelFormat := pf32bit;
  FDrawCalls[True] := TDrawCalls.Create();
  FDrawCalls[False] := TDrawCalls.Create();
  FCamera := TCamera.Create();
  SetResolution(512, 512);
  FMeshList := TObjectList<TMesh>.Create();

  FTimer := TStopWatch.Create(False);

  FWorkers := TObjectList<TRenderWorker>.Create();
  SpinupWorkers(AWorker);
end;

destructor TMundusRenderer.Destroy;
begin
  TerminateWorkers;
  FWorkers.Free;
  FMeshList.Free();
  FBackBuffer[True].Free();
  FBackBuffer[False].Free();
  FDrawCalls[True].Free;
  FDrawCalls[False].Free;
  FTimer.Free;
  FCamera.Free;
  inherited;
end;

procedure TMundusRenderer.DispatchCalls(ACanvas: TCanvas; ACalls: TDrawCalls);
var
  LWorker: TRenderWorker;
  LBackBuffer, LFrontBuffer: Boolean;
  LFPS: Integer;
begin
  LBackBuffer := FCurrentBuffer;
  LFrontBuffer := not FCurrentBuffer;

  //ResetBackBuffer from last frame
  UpdateBufferResolution(LFrontBuffer, FResolutionX, FResolutionY);
  ClearBuffer(LFrontBuffer);
  ClearDepthBuffer(LFrontBuffer);

  //wait for workers to finish frame
  WaitForRender;

  //load workers with new stuff and start
  FWorkerFPS := High(FWorkerFPS);
  for LWorker in FWorkers do
  begin
    LWorker.DrawCalls := ACalls;
    LWorker.PixelBuffer := FBackBuffer[LFrontBuffer];
    LWorker.DepthBuffer := @FDepthBuffer[LFrontBuffer];
    LWorker.ResolutionX := FResolutionX;
    LWorker.ResolutionY := FResolutionY;
    LFPS := LWorker.FPS;
    if LFPS < FWorkerFPS then
      FWorkerFPS := LFPS;
    LWorker.StartRender;
  end;

  //Draw Backbuffer to FrontBuffer
  DoAfterFrame(FBackBuffer[LBackBuffer].Canvas);
  ACanvas.Draw(0, 0, FBackBuffer[LBackBuffer]);
  //flip buffers
  FCurrentBuffer := not FCurrentBuffer;
end;

procedure TMundusRenderer.DoAfterFrame(ACanvas: TCanvas);
begin
  if Assigned(FOnAfterFrame) then
  begin
    FOnAfterFrame(ACanvas);
  end;
end;

function TMundusRenderer.GenerateDrawCalls(const AViewMatrix: TMatrix4x4): TDrawCalls;
var
  LMesh: TMesh;
  LCall: PDrawCall;
  LMove, LWorld: TMatrix4x4;
  LRotationX, LRotationY, LRotationZ: TMatrix4x4;
  LProjection: TMatrix4x4;
begin
  Result := FDrawCalls[not FCurrentBuffer];
  Result.Reset;
  for LMesh in FMeshList do
  begin
    LCall := Result.Add;
    LWorld := AViewMatrix;
    LRotationX.SetAsRotationXMatrix(DegToRad(LMesh.Rotation.X));
    LRotationY.SetAsRotationYMatrix(DegToRad(LMesh.Rotation.Y));
    LRotationZ.SetAsRotationZMatrix(DegToRad(LMesh.Rotation.Z));

    LMove.SetAsMoveMatrix(LMesh.Position.X, LMesh.Position.Y, LMesh.Position.Z);
    LMove.MultiplyMatrix4D(LRotationX);
    LMove.MultiplyMatrix4D(LRotationY);
    LMove.MultiplyMatrix4D(LRotationZ);

    LWorld.MultiplyMatrix4D(LMove);

    LProjection.SetAsPerspectiveProjectionMatrix(0.1, 10000, 0.7, FResolutionX/FResolutionY);
    LProjection.MultiplyMatrix4D(LWorld);

    TransformMesh(LMesh, LWorld, LProjection, LCall);
    LCall.Shader := LMesh.Shader;
  end;
end;

function TMundusRenderer.GetCurrentFPS: Integer;
begin
  Result := FFPS;
end;

function TMundusRenderer.GetRenderWorkers: Integer;
begin
  Result := FWorkers.Count;
end;

procedure TMundusRenderer.RenderFrame(ACanvas: TCanvas);
var
  LDrawCalls: TDrawCalls;
  LViewMoveMatrix: TMatrix4x4;
  LMicro: UInt64;
begin
  FTimer.Start();

  LViewMoveMatrix.SetAsMoveMatrix(FCamera.Position.X, FCamera.Position.Y, FCamera.Position.Z);
  LViewMoveMatrix.MultiplyMatrix4D(FCamera.Rotation);

  LDrawCalls := GenerateDrawCalls(LViewMoveMatrix.Inverse);
  DispatchCalls(ACanvas, LDrawCalls);

  FTimer.Stop();
  LMicro := FTimer.ElapsedMicroseconds;
  if LMicro > 0 then
    FFPS := Min(FWorkerFPS, 1000000 div LMicro)
  else
    FFPS := FWorkerFPS;
end;

procedure TMundusRenderer.SetDepthBufferSize(ABuffer: Boolean; AWidth, AHeight: Integer);
begin
  SetLength(FDepthBuffer[ABuffer], AHeight*AWidth);
end;

procedure TMundusRenderer.SetResolution(AWidth, AHeight: Integer);
begin
  FResolutionX := AWidth div CQuadSize * CQuadSize;
  FResolutionY := AHeight div CQuadSize * CQuadSize;
end;

procedure TMundusRenderer.SpinupWorkers(AWorkerCount: Integer);
var
  i: Integer;
  LWorker: TRenderWorker;
begin
  SetLength(FRenderFences, AWorkerCount);
  for i := 0 to Pred(AWorkerCount) do
  begin
    LWorker := TRenderWorker.Create();
    LWorker.BlockSteps := AWorkerCount;
    LWorker.BlockOffset := i;
    FWorkers.Add(LWorker);
    FRenderFences[i] := LWorker.RenderFence;
    LWorker.Start;
  end;
end;

procedure TMundusRenderer.TerminateWorkers;
var
  LWorker: TRenderWorker;
begin
  for LWorker in FWorkers do
    LWorker.Terminate;
end;

procedure TMundusRenderer.TransformMesh(AMesh: TMesh; AWorld, AProjection: TMatrix4x4; ATargetCall: PDrawCall);
var
  i: Integer;
  LVertex, LVertexA, LVertexB, LVertexC, LNormal: TFloat4;
  LTriangle: PTriangle;
  LShader: TShader;
  LBuffer: TVertexAttributeBuffer;
  LBufferSize: Integer;
  LVInput: TVertexShaderInput;
  LIndices: TArray<Integer>;
  LClippedTriangle: TTriangle;
begin
  LBufferSize := AMesh.Shader.GetAttributeBufferSize;
  SetLength(LBuffer, LBufferSize);
  LShader := AMesh.Shader.Create();
  try
    if Assigned(FOnInitValueBuffer) then
      FOnInitValueBuffer(AMesh, @ATargetCall.Values);
    LShader.BindBuffer(@ATargetCall.Values);

    //transform all vertices
    for i := 0 to High(AMesh.Vertices) do
    begin
      LVertex.Element[0] := AMesh.Vertices[i].X;
      LVertex.Element[1] := AMesh.Vertices[i].Y;
      LVertex.Element[2] := AMesh.Vertices[i].Z;
      LVertex.Element[3] := 1;
      LVInput.VertexID := i;
      LShader.VertexShader(AWorld, AProjection, LVertex, LVInput, LBuffer);
      ATargetCall.AddVertex(LVertex, LBuffer);
    end;

    //add visible triangles
    for LTriangle in AMesh.Triangles do
    begin
      LVertexA := ATargetCall.Vertices[LTriangle.VertexA];
      LVertexB := ATargetCall.Vertices[LTriangle.VertexB];
      LVertexC := ATargetCall.Vertices[LTriangle.VertexC];
      LNormal.CalculateSurfaceNormal(LVertexA, LVertexB, LVertexC);
      if (LNormal.Z < 0) then
      begin
        LIndices := ClipPolygon(ATargetCall, LTriangle.VertexA, LTriangle.VertexB, LTriangle.VertexC);
        //if less than 3, it is fully clipped
        if Length(LIndices) >= 3 then
        begin
          LClippedTriangle.VertexA := LIndices[0];
          LClippedTriangle.VertexB := LIndices[1];
          LClippedTriangle.VertexC := LIndices[2];
          ATargetCall.AddTriangle(@LClippedTriangle);
          for i := 3 to High(LIndices) do
          begin
            LClippedTriangle.VertexA := LIndices[0];
            LClippedTriangle.VertexB := LIndices[i-1];
            LClippedTriangle.VertexC := LIndices[i];
            ATargetCall.AddTriangle(@LClippedTriangle);
          end;
        end;
      end;
    end;

    //normalize all vertices
    for i := 0 to High(ATargetCall.Vertices) do
      ATargetCall.Vertices[i].NormalizeKeepW;
  finally
    LShader.Free;
  end;
end;

procedure TMundusRenderer.UpdateBufferResolution(ABuffer: Boolean; AWidth, AHeight: Integer);
var
  LBuffer: TBitmap;
begin
  LBuffer := FBackBuffer[ABuffer];
  if (LBuffer.Width <> AWidth) or (LBuffer.Height <> AHeight) then
  begin
    LBuffer.SetSize(AWidth, Aheight);
    FFirstLIne := LBuffer.ScanLine[0];
    FLineLength := (NativeInt(LBuffer.Scanline[1]) - NativeInt(FFirstLine)) div SizeOf(TRGB32);
    LBuffer.Canvas.Pen.Color := clBlack;
    LBuffer.Canvas.Brush.Color := clBlack;
    SetDepthBufferSize(ABuffer, AWidth, AHeight);
    ClearDepthBuffer(ABuffer);
  end;
end;

procedure TMundusRenderer.WaitForRender;
begin
  WaitForMultipleObjects(Length(FRenderFences), @FRenderFences[0], True, INFINITE);
end;

{ some functions }

function RGB32(ARed, AGreen, ABlue, AAlpha: Byte): TRGB32;
begin
  Result.R := ARed;
  Result.G := AGreen;
  Result.B := ABlue;
  Result.A := AAlpha;
end;

end.
