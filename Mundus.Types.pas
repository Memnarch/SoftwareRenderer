unit Mundus.Types;

interface

uses
  Mundus.Math;

type
  TRGB32 = packed record
    B, G, R, A: Byte;
  end;

  PRGB32 = ^TRGB32;

  TRGB32Array = packed array[0..MaxInt div SizeOf(TRGB32)-1] of TRGB32;
  PRGB32Array = ^TRGB32Array;

  TDepthBuffer = array of array of Single;
  PDepthsBuffer = ^TDepthBuffer;

  TVertexAttributeBuffer = TArray<Byte>;
  TRasterizer = procedure(
    AMaxResolutionX, AMaxResolutionY: Integer;
    const AVerctorA, AvectorB, AvectorC: TFloat4;
    const AAttributesA, AAttributesB, AAttributesC: TVertexAttributeBuffer;
    AShader: TObject;
    APixelBuffer: PRGB32Array;
    ADepthBuffer: PDepthsBuffer;
    ABlockOffset, ABlockStep: Integer);

  TVector = record
    X, Y, Z: Integer;
    constructor Create(AX, AY, AZ: Integer);
  end;

  TUV = record
    U, V: Single;
  end;

  TTriangle = record
    VertexA, VertexB, VertexC: Integer;
    UVA, UVB, UVC: TUV;
  end;

  PTriangle = ^TTriangle;

  TVectorClass = class
  private
    FX, FY, FZ: Integer;
  public
    constructor Create(AX, AY, AZ: Integer);
    property X: Integer read FX write FX;
    property Y: Integer read FY write FY;
    property Z: Integer read FZ write FZ;
  end;

  TTriangleClass = class
  private
    FVertexA, FVertexB, FVertexC: Integer;
    FUVB: TUV;
    FUVC: TUV;
    FUVA: TUV;
  public
    constructor Create(AVertexA, AvertexB, AvertexC: Integer);
    procedure SetUV(AUVA, AUVB, AUVC: TUV);
    property VertexA: Integer read FVertexA write FVertexA;
    property VertexB: Integer read FVertexB write FVertexB;
    property VertexC: Integer read FVertexC write FVertexC;
    property UVA: TUV read FUVA write FUVA;
    property UVB: TUV read FUVB write FUVB;
    property UVC: TUV read FUVC write FUVC;
  end;

  function Vector(AX, AY, AZ: Integer): TVector;
  function UV(AU, AV: Single): TUV;
  function Triangle(AVertexA, AVertexB, AVertexC: Integer): TTriangle;

  function RGB32(R, G, B, A: Byte): TRGB32;

const
  CQuadSize = 8;

implementation

{ TTriangleClass }

constructor TTriangleClass.Create(AVertexA, AvertexB, AvertexC: Integer);
begin
  FVertexA := AVertexA;
  FVertexB := AvertexB;
  FVertexC := AvertexC;
  FUVA :=  UV(0, 0);
  FUVB := UV(0, 0);
  FUVC := UV(0, 0);
end;

procedure TTriangleClass.SetUV(AUVA, AUVB, AUVC: TUV);
begin
  FUVA := AUVA;
  FUVB := AUVB;
  FUVC := AUVC;
end;

{ TVectorClass }

constructor TVectorClass.Create(AX, AY, AZ: Integer);
begin
  FX := AX;
  FY := AY;
  FZ := AZ;
end;

{ Some Functions }
function Vector(AX, AY, AZ: Integer): TVector;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Z := AZ;
end;

function Triangle(AVertexA, AVertexB, AVertexC: Integer): TTriangle;
begin
  Result.VertexA := AVertexA;
  Result.VertexB := AVertexB;
  Result.VertexC := AVertexC;
end;

function UV(AU, AV: Single): TUV;
begin
  Result.U := AU;
  Result.V := AV;
end;

{ TVector }

constructor TVector.Create(AX, AY, AZ: Integer);
begin
  X := AX;
  Y := AY;
  Z := AZ;
end;

function RGB32(R, G, B, A: Byte): TRGB32;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
  Result.A := A;
end;

end.
