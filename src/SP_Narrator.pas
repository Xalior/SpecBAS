// Copyright (C) 2026 By Paul Dunn
//
// This file is part of the SpecBAS BASIC Interpreter, which is in turn
// part of the SpecOS project.
//
// SpecBAS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// SpecBAS is distributed in the hope that it will be entertaining,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with SpecBAS.  If not, see <http://www.gnu.org/licenses/>.

unit SP_Narrator;

// SP_Narrator.pas
// Amiga Narrator-style formant speech synthesiser for SpecBAS.
//
// Synthesis model: cascade formant (source-filter)
//   Source  : buzz train (voiced) + white/pink noise (unvoiced)
//   Filter  : 4 x second-order IIR resonators in cascade
//   Nasals  : additional anti-resonator (notch) at ~800 Hz
//   Output  : 16-bit signed mono PCM at 44100 Hz
//
// Public interface:
//   SP_NarratorDefaultParams      - fills a TNarratorParams with defaults
//   SP_NarratorFindAllophone      - returns index for a name string, -1 if unknown
//   SP_NarratorSynth              - phoneme string -> PCM buffer
//   SP_Say                        - synthesise and play (sync or async)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses
  SysUtils, Math, Bass, SP_Util;

Const

  SP_NARRATOR_SAMPLERATE = 44100;
  SP_NARRATOR_ALLOPHONE_COUNT = 55;

  // Default parameter values - male voice
  SP_NARRATOR_DEFAULT_PITCH  = 110;   // Hz
  SP_NARRATOR_DEFAULT_RATE   = 150;   // nominal words/min scale
  SP_NARRATOR_DEFAULT_SEX    = 0;     // 0=male, 1=female
  SP_NARRATOR_DEFAULT_MODE   = 0;     // 0=natural, 1=robotic
  SP_NARRATOR_DEFAULT_VOLUME = 1.0;

  // Coefficient update interval - recalculate filter coefficients every N samples.
  // 220 samples ≈ 5 ms at 44100 Hz; smooth enough, cheap enough.
  SP_NARRATOR_COEFF_INTERVAL = 441;

Type

  TNarratorParams = Record
    Pitch:  Integer;   // fundamental frequency Hz, 65..320
    Rate:   Integer;   // duration scale, 65..400 (150 = normal)
    Sex:    Integer;   // 0=male, 1=female
    Mode:   Integer;   // 0=natural, 1=robotic (flat pitch)
    Volume: Single;    // 0..1
  End;

  TAlloPhone = Record
    Name:     String[4];
    DurMs:    Integer;             // nominal duration ms at Rate=150
    F:        Array[1..4] of Integer;   // formant centre frequencies Hz
    BW:       Array[1..4] of Integer;   // formant bandwidths Hz
    BuzzAmp:  Single;              // voiced source level 0..1
    NoiseAmp: Single;              // noise source level 0..1
    Voiced:   Boolean;
    Nasal:    Boolean;
    Stop:     Boolean;             // closure+burst behaviour
  End;

  TFormantFilter = Record
    A1, A2: Double;   // IIR feedback coefficients
    Gain:   Double;   // output normalisation
    Y1, Y2: Double;   // delay-line state
  End;

  // Anti-resonator for nasals - same structure, different meaning
  TAntiResonator = Record
    A1, A2: Double;
    Gain:   Double;   // DC normalisation: 1/(1-A1-A2) keeps unity gain outside the notch
    X1, X2: Double;   // feed-forward delay (uses input history, not output)
  End;

  // Internal state passed through the synthesis loop
  TSynthState = Record
    Filters:      Array[1..4] of TFormantFilter;
    NasalNotch:   TAntiResonator;
    BuzzPhase:    Double;    // phase accumulator for glottal pulse, 0..1
    NoiseSeed:    LongWord;  // LCG state
    PrevF:        Array[1..4] of Double;  // formant freqs at end of last allophone
    PrevBW:       Array[1..4] of Double;  // bandwidths at end of last allophone
    PreEmphX1:    Double;
    NoiseFilter:  TFormantFilter;
    BrightX1:     Double;
    PinkNoiseX1:  Double;
  End;

Const

  // -----------------------------------------------------------------------
  // Allophone table - 59 entries, index 0..58
  // Formant frequencies and bandwidths from phonetic literature tuned to
  // approximate the Amiga Narrator.device male voice characteristic.
  // -----------------------------------------------------------------------

  AlloPhones: Array[0..SP_NARRATOR_ALLOPHONE_COUNT - 1] of TAlloPhone = (

    // --- Vowels ---
    (Name:'IY';  DurMs:130; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'IH';  DurMs:85;  F:(390,1990,2550,3850); BW:(50,200,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'EH';  DurMs:80;  F:(530,1840,2480,3850); BW:(60,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AE';  DurMs:100; F:(660,1720,2410,3850); BW:(70,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AA';  DurMs:130; F:(730,1090,2440,3850); BW:(70,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AH';  DurMs:80;  F:(640,1190,2390,3850); BW:(70,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AO';  DurMs:110; F:(570, 840,2410,3850); BW:(60,150,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'OW';  DurMs:130; F:(360, 640,2390,3850); BW:(50,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'UH';  DurMs:100; F:(440,1020,2240,3850); BW:(50,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'UW';  DurMs:120; F:(300, 870,2240,3850); BW:(40,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'ER';  DurMs:120; F:(490,1350,1690,3850); BW:(70,150,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AX';  DurMs:80;  F:(490,1350,1690,3850); BW:(70,200,200,250); BuzzAmp:0.70; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),

    // --- Diphthongs (target = endpoint; long duration + slow transition = movement) ---
    (Name:'AY';  DurMs:140; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AW';  DurMs:200; F:(300,870,2240,3850);  BW:(40,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),

    (Name:'OY';  DurMs:150; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'EY';  DurMs:130; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),

    // --- Semivowels / liquids ---
    (Name:'WW';  DurMs:80;  F:(290, 610,2150,3850); BW:(40, 60,250,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),
    (Name:'RR';  DurMs:80;  F:(490,1350,1690,3850); BW:(60,100,200,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),
    (Name:'LL';  DurMs:70;  F:(310,1050,2880,3850); BW:(40,150,250,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),
    (Name:'YY';  DurMs:90;  F:(280,2250,3070,3850); BW:(40,200,250,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),

    // --- Nasals ---
    (Name:'MM'; DurMs:110; F:(270, 900,2000,3300); BW:(350,500,600,400); BuzzAmp:1.00; NoiseAmp:0.05; Voiced:True; Nasal:True; Stop:False),
    (Name:'NN'; DurMs:100; F:(250,1400,2600,3300); BW:(350,500,600,400); BuzzAmp:1.00; NoiseAmp:0.05; Voiced:True; Nasal:True; Stop:False),
    (Name:'NX'; DurMs:70;  F:(250,2200,2600,3300); BW:(350,500,600,400); BuzzAmp:1.00; NoiseAmp:0.05; Voiced:True; Nasal:True; Stop:False),

    // --- Unvoiced fricatives ---
    (Name:'FF'; DurMs:40;  F:(900,1220,2090,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.25; Voiced:False; Nasal:False; Stop:False),
    (Name:'TH'; DurMs:80;  F:(900,1480,2500,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.30; Voiced:False; Nasal:False; Stop:False),
    (Name:'SS'; DurMs:100; F:(900,2250,3200,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.90; Voiced:False; Nasal:False; Stop:False),
    (Name:'SH'; DurMs:100; F:(900,1750,2800,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.85; Voiced:False; Nasal:False; Stop:False),
    (Name:'HH'; DurMs:70;  F:(900,1200,2500,3500); BW:(400,400,300,300); BuzzAmp:0.00; NoiseAmp:0.55; Voiced:False; Nasal:False; Stop:False),

    // --- Voiced fricatives ---
    (Name:'VV'; DurMs:80;  F:(280,1220,2090,3850); BW:(40,200,250,250); BuzzAmp:0.50; NoiseAmp:0.20; Voiced:True;  Nasal:False; Stop:False),
    (Name:'DH'; DurMs:70;  F:(280,1480,2500,3850); BW:(40,200,250,250); BuzzAmp:0.25; NoiseAmp:0.15; Voiced:True;  Nasal:False; Stop:False),
    (Name:'ZZ';  DurMs:90; F:(280,2250,2800,3850); BW:(40,200,250,250); BuzzAmp:0.50; NoiseAmp:0.60; Voiced:True;  Nasal:False; Stop:False),
    (Name:'ZH';  DurMs:80; F:(280,1750,2480,3850); BW:(40,200,250,250); BuzzAmp:0.50; NoiseAmp:0.50; Voiced:True;  Nasal:False; Stop:False),

    // --- Affricates ---
    (Name:'CH'; DurMs:110; F:(400,1750,2480,3850); BW:(300,200,250,250); BuzzAmp:0.00; NoiseAmp:0.85; Voiced:False; Nasal:False; Stop:True),
    (Name:'JH'; DurMs:110; F:(400,1750,2480,3850); BW:(300,200,250,250); BuzzAmp:0.40; NoiseAmp:0.70; Voiced:True;  Nasal:False; Stop:True),

    // --- Unvoiced stops ---
    (Name:'PP'; DurMs:80;  F:(400, 600,2050,3850); BW:(150,100,250,250); BuzzAmp:0.00; NoiseAmp:0.35; Voiced:False; Nasal:False; Stop:True),
    (Name:'TT'; DurMs:80;  F:(400,1750,2600,3850); BW:(300,200,250,250); BuzzAmp:0.00; NoiseAmp:0.70; Voiced:False; Nasal:False; Stop:True),
    (Name:'KK'; DurMs:90;  F:(400,1990,2850,3850); BW:(300,200,250,250); BuzzAmp:0.00; NoiseAmp:0.70; Voiced:False; Nasal:False; Stop:True),

    // --- Voiced stops ---
    (Name:'BB'; DurMs:80;  F:(400,600,2050,3850);  BW:(150,100,250,250); BuzzAmp:0.50; NoiseAmp:0.55; Voiced:True;  Nasal:False; Stop:True),
    (Name:'DD'; DurMs:80;  F:(400,1750,2600,3850); BW:(300,200,250,250); BuzzAmp:0.50; NoiseAmp:0.35; Voiced:True;  Nasal:False; Stop:True),
    (Name:'GG'; DurMs:90;  F:(400,1990,2850,3850); BW:(300,200,250,250); BuzzAmp:0.50; NoiseAmp:0.30; Voiced:True;  Nasal:False; Stop:True),

    // --- Flap ---
    (Name:'DX';  DurMs:30;  F:(490,1350,1690,3850); BW:(70,150,200,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),

    // Missing Amiga
    (Name:'IX';  DurMs:55;  F:(430,1700,2550,3850); BW:(60,200,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'OH';  DurMs:90;  F:(480, 760,2400,3850); BW:(50,150,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'WH';  DurMs:90;  F:(290, 610,2150,3850); BW:(40, 60,250,250); BuzzAmp:0.00; NoiseAmp:0.60; Voiced:False; Nasal:False; Stop:False),
    (Name:'RX';  DurMs:100; F:(450,1300,1600,3850); BW:(60,100,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'LX';  DurMs:90;  F:(400, 850,2700,3850); BW:(50,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'KH';  DurMs:100; F:(400,1990,2850,3850); BW:(200,300,300,300);BuzzAmp:0.00; NoiseAmp:0.80; Voiced:False; Nasal:False; Stop:False),
    (Name:'QQ';  DurMs:30;  F:(0,0,0,0);            BW:(0,0,0,0);        BuzzAmp:0.00; NoiseAmp:0.00; Voiced:False; Nasal:False; Stop:True),
    (Name:'QX';  DurMs:80;  F:(0,0,0,0);            BW:(0,0,0,0);        BuzzAmp:0.00; NoiseAmp:0.00; Voiced:False; Nasal:False; Stop:False),

    // --- Pauses ---
    (Name:'PA0'; DurMs:5;   F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA1'; DurMs:10;  F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA2'; DurMs:30;  F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA3'; DurMs:50;  F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA4'; DurMs:100; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA5'; DurMs:200; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False)
  );

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

Procedure SP_NarratorDefaultParams(Out Params: TNarratorParams);
Function  SP_NarratorFindAllophone(Const Name: aString): Integer;
Function  SP_NarratorSynth(Const Phonemes: aString; Const Params: TNarratorParams): TBytes;
Procedure SP_Say(Const Phonemes: aString; Const Params: TNarratorParams; Async: Boolean);

implementation

Uses SP_Sound, SP_SysVars, SP_Input, SP_Main, SP_NarratorTranslator;

// ---------------------------------------------------------------------------
// Filter coefficient calculation
// ---------------------------------------------------------------------------

Procedure InitFormant(Var F: TFormantFilter; Freq, BW, SR: Double);
Var
  r, c: Double;
Begin
  If Freq <= 0 Then Begin
    F.A1   := 0;
    F.A2   := 0;
    F.Gain := 0;
    Exit;
  End;
  r      := Exp(-Pi * BW / SR);
  c      := Cos(2 * Pi * Freq / SR);
  F.A1   := 2 * r * c;
  F.A2   := -(r * r);
  F.Gain := 1.0 - r;
End;

Function ProcessFormant(Var F: TFormantFilter; x: Double): Double;
Var
  y: Double;
Begin
  y    := x * F.Gain + F.A1 * F.Y1 + F.A2 * F.Y2;
  F.Y2 := F.Y1;
  F.Y1 := y;
  Result := y;
End;

Procedure InitAntiResonator(Var A: TAntiResonator; Freq, BW, SR: Double);
Var
  r, c, DC: Double;
Begin
  r    := Exp(-Pi * BW / SR);
  c    := Cos(2 * Pi * Freq / SR);
  A.A1 := 2 * r * c;
  A.A2 := -(r * r);
  // DC gain of the raw feedforward filter H(z)=1-A1z^-1-A2z^-2 is 1-A1-A2 (~0.03
  // for typical nasal parameters). Without normalisation every frequency passing
  // through the anti-resonator is attenuated ~30 dB, making nasals nearly silent.
  DC     := 1.0 - A.A1 - A.A2;
  If DC <> 0 Then A.Gain := 1.0 / DC Else A.Gain := 1.0;
End;

Function ProcessAntiResonator(Var A: TAntiResonator; x: Double): Double;
Begin
  Result := (x - A.A1 * A.X1 - A.A2 * A.X2) * A.Gain;
  A.X2   := A.X1;
  A.X1   := x;
End;

// ---------------------------------------------------------------------------
// Source generators
// ---------------------------------------------------------------------------

// Glottal buzz - asymmetrical Rosenberg-style pulse
// Slow opening phase, rapid snapping close phase.
// Generates much richer high-order harmonics than a simple cosine,
// completely eliminating the "blurry/muffled" sound from vowels.

Function GlottalBuzz(Var Phase: Double; PitchHz, SR: Double): Double;
Begin
  // Asymmetrical Rosenberg-style pulse
  // 0.00 to 0.40 : Gradual opening phase
  // 0.40 to 0.45 : Rapid snapping close (generates high frequency clarity)
  // 0.45 to 1.00 : Closed phase
  If Phase < 0.40 Then
    Result := 0.5 - 0.5 * Cos(Phase / 0.40 * Pi)
  Else If Phase < 0.45 Then
    Result := 0.5 + 0.5 * Cos((Phase - 0.40) / 0.05 * Pi)
  Else
    Result := 0;

  Phase := Phase + PitchHz / SR;
  If Phase >= 1.0 Then Phase := Phase - 1.0;
End;

// Fast inline LCG white noise
Function WhiteNoise(Var Seed: LongWord): Double;
Begin
  Seed := LongWord(UInt64(Seed) * 1664525 + 1013904223); // Numerical Recipes LCG
  Result := (Integer(Seed) / 2147483648.0); // signed divide: -1..+1
End;

// Dedicated target frequencies for parallel fricative/burst noise
Procedure UpdateNoiseColour(Var State: TSynthState;
                            Const Allo: TAlloPhone);
Var
  Name: aString;
Begin
  If Allo.NoiseAmp <= 0 Then Exit;

  Name := SP_Util.Upper(aString(Allo.Name));

  // Tightened bandwidths: creates distinct "tonal" hits (clicks/pops)
  // instead of broad, fuzzy white noise static.
  If      (Name = 'SS') Or (Name = 'ZZ') Then
    InitFormant(State.NoiseFilter, 5500, 2000, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'SH') Or (Name = 'ZH') Or (Name = 'CH') Or (Name = 'JH') Then
    InitFormant(State.NoiseFilter, 2500, 400, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'TT') Or (Name = 'DD') Then
    InitFormant(State.NoiseFilter, 3800, 600, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'KK') Or (Name = 'GG') Then
    InitFormant(State.NoiseFilter, 2200, 500, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'PP') Or (Name = 'BB') Then
    InitFormant(State.NoiseFilter, 1200, 400, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'FF') Or (Name = 'VV') Then
    InitFormant(State.NoiseFilter, 4500, 1500, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'TH') Or (Name = 'DH') Then
    InitFormant(State.NoiseFilter, 6500, 2000, SP_NARRATOR_SAMPLERATE)
  Else If (Name = 'KK') Or (Name = 'GG') Or (Name = 'KH') Then
    InitFormant(State.NoiseFilter, 2200, 500, SP_NARRATOR_SAMPLERATE)
  Else
    InitFormant(State.NoiseFilter, 2500, 1000, SP_NARRATOR_SAMPLERATE);
  // Clear delay-line state so stale energy from the previous allophone's
  // noise filter does not produce a transient when the filter shape changes.
  State.NoiseFilter.Y1 := 0;
  State.NoiseFilter.Y2 := 0;
End;

// ---------------------------------------------------------------------------
// Coefficient frame update
// ---------------------------------------------------------------------------

Procedure UpdateFormantCoeffs(Var State:    TSynthState;
                              Const CurAllo: TAlloPhone;
                              Const Params:  TNarratorParams;
                                    Progress: Double;
                              Const PrevF:  Array of Double;
                              Const PrevBW: Array of Double);
Var
  i: Integer;
  TargF, TargBW, CurF, CurBW: Double;
  SexScale: Double;
  BWScale:  Double;
Begin
  If Params.Sex = 1 Then SexScale := 1.15 Else SexScale := 1.0;

  // Narrowing bandwidths increases the sharpness/clarity of formants
  If CurAllo.Stop Then
    BWScale := 0.85
  Else If CurAllo.Nasal Then
    BWScale := 0.90
  Else If CurAllo.NoiseAmp > CurAllo.BuzzAmp Then
    BWScale := 0.85
  Else
    BWScale := 0.70; // Tightened for crystal-clear vowels

  For i := 1 To 4 Do Begin
    TargF := CurAllo.F[i];
    If i = 3 Then TargF := TargF * 1.07
    Else If i = 4 Then TargF := TargF * 1.05;

    TargBW := CurAllo.BW[i] * BWScale;

    If i > 1 Then TargF := TargF * SexScale;
    If Progress < 1.0 Then Begin
      CurF  := PrevF[i-1]  + (TargF  - PrevF[i-1])  * Progress;
      CurBW := PrevBW[i-1] + (TargBW - PrevBW[i-1]) * Progress;
    End Else Begin
      CurF  := TargF;
      CurBW := TargBW;
    End;

    InitFormant(State.Filters[i], CurF, CurBW, SP_NARRATOR_SAMPLERATE);
    State.Filters[i].Gain := 1.0 - State.Filters[i].A1 - State.Filters[i].A2;
  End;

  If CurAllo.Nasal Then
    InitAntiResonator(State.NasalNotch, 1200, 200, SP_NARRATOR_SAMPLERATE);
End;

Procedure SP_NarratorDefaultParams(Out Params: TNarratorParams);
Begin
  Params.Pitch  := SP_NARRATOR_DEFAULT_PITCH;
  Params.Rate   := SP_NARRATOR_DEFAULT_RATE;
  Params.Sex    := SP_NARRATOR_DEFAULT_SEX;
  Params.Mode   := SP_NARRATOR_DEFAULT_MODE;
  Params.Volume := SP_NARRATOR_DEFAULT_VOLUME;
End;

Function SP_NarratorFindAllophone(Const Name: aString): Integer;
Var
  i: Integer;
  Upper: aString;
Begin
  Upper := SP_Util.Upper(Name);

  // --- AMIGA NARRATOR ARPABET ALIASES ---
  If Upper = 'P' Then Upper := 'PP';
  If Upper = 'B' Then Upper := 'BB';
  If Upper = 'T' Then Upper := 'TT';
  If Upper = 'D' Then Upper := 'DD';
  If Upper = 'K' Then Upper := 'KK';
  If Upper = 'G' Then Upper := 'GG';
  If Upper = 'M' Then Upper := 'MM';
  If Upper = 'N' Then Upper := 'NN';
  If Upper = 'F' Then Upper := 'FF';
  If Upper = 'V' Then Upper := 'VV';
  If Upper = 'S' Then Upper := 'SS';
  If Upper = 'Z' Then Upper := 'ZZ';
  If Upper = 'R' Then Upper := 'RR';
  If Upper = 'L' Then Upper := 'LL';
  If Upper = 'W' Then Upper := 'WW';
  If Upper = 'Y' Then Upper := 'YY';
  If (Upper = 'H') Or (Upper = '/H') Then Upper := 'HH';
  If (Upper = 'C') Or (Upper = '/C') Then Upper := 'KH';
  If Upper = 'J' Then Upper := 'JH';
  If Upper = 'Q' Then Upper := 'QQ';
  // --------------------------------------

  For i := 0 To SP_NARRATOR_ALLOPHONE_COUNT - 1 Do
    If aString(AlloPhones[i].Name) = Upper Then Begin
      Result := i;
      Exit;
    End;
  Result := -1;
End;

Function ParsePhonemes(Const Phonemes: aString;
                       Out   Indices:  Array of Integer;
                       Out   Stresses: Array of Integer): Integer;
Var
  s:     aString;
  p, q:  Integer;
  Token: aString;
  Idx:   Integer;
  Count:       Integer;
  StressDigit: Integer;
Begin
  Count := 0;
  s := SP_Trim(Phonemes);

  If (Length(s) >= 2) And (s[1] = '/') Then s := Copy(s, 2, Length(s));
  If (Length(s) >= 1) And (s[Length(s)] = '/') Then s := Copy(s, 1, Length(s) - 1);
  s := SP_Trim(s);

  p := 1;
  While p <= Length(s) Do Begin
    While (p <= Length(s)) And (s[p] <= ' ') Do Inc(p);
    If p > Length(s) Then Break;

    q := p;
    While (q <= Length(s)) And (s[q] > ' ') Do Inc(q);
    Token := SP_Util.Upper(Copy(s, p, q - p));
    p := q;

    StressDigit := 1; // default = normal stress if no digit present
    While (Length(Token) > 0) And (Token[Length(Token)] In ['0'..'9']) Do Begin
      StressDigit := Ord(Token[Length(Token)]) - Ord('0');
      Token := Copy(Token, 1, Length(Token) - 1);
    End;

    Idx := SP_NarratorFindAllophone(Token);
    If (Idx >= 0) And (Count < Length(Indices)) Then Begin
      Indices[Count]  := Idx;
      Stresses[Count] := StressDigit;
      Inc(Count);
    End;
  End;

  Result := Count;
End;

// ---------------------------------------------------------------------------
// SP_NarratorSynth - main synthesis function
// ---------------------------------------------------------------------------

Function SP_NarratorSynth(Const Phonemes: aString;
                           Const Params:   TNarratorParams): TBytes;
Var
  Indices:       Array of Integer;
  AlloCount:     Integer;
  TotalSamples:  Integer;
  BufBytes:      Integer;
  WritePos:      Integer;
  ai:            Integer;
  PrevAllo, Allo: TAlloPhone;
  DurSamples:    Integer;
  TransSamples:  Integer;
  StopSamples:   Integer;
  si:            Integer;
  NextCoeffAt:   Integer;
  Progress:      Double;
  Filtered:      Double;
  FRaw:          Double;
  ClampedS:      Integer;
  DeClickLen:    Integer;
  i:             Integer;
  Scale:         Double;
  State:         TSynthState;
  RateScale:     Double;
  SavePrevF:     Array[1..4] of Double;
  SavePrevBW:    Array[1..4] of Double;
  PitchHz:       Double;
  PitchStart:    Double;
  PitchEnd:      Double;
  AlloProgress:  Double;
  OnsetSamples:  Integer;
  NoiseScale:    Double;
  BurstEnv:      Double;
  BurstTime:     Integer;
  BurstRamp:     Double;
  DecayRamp:     Double;
  PlosiveLen:    Integer;
  NoiseAttack:   Double;
  FadeLen:       Integer;
  ClosureFade:   Double;
  PrevBuzz:      Double;
  TempFilter:    Double;
  RMSSum:        Double;
  RMSVal:        Double;
  SampleCount:   Integer;
  Idx:           Integer;
  AlloName:      aString;
  IsDiphthong:    Boolean;
  BypassF1:       Boolean;
  BuzzPart:       Double;
  AspPart:        Double;
  FricPart:       Double;
  TargetEmph:     Double;
  CurEmph:        Double;
  Stresses:       Array of Integer;  // parallel to Indices; 0=unstressed 1=normal 2=stressed
  StressLevel:    Integer;
  StressDurScale: Double;            // duration multiplier for this allophone
  StressAmpScale: Double;            // BuzzAmp multiplier
  StressPitchPeak:Double;            // Hz added at midpoint of voiced allophone
  StressPitchArc: Double;            // per-sample pitch offset
  EffBuzzAmp:     Double;            // stress-scaled buzz amplitude for this sample
  rawNoise:       Double;
  AmpFadeLen:     Integer;
  AmpFade:        Double;
  CurBuzzAmp:     Double;
  CurNoiseAmp:    Double;

  Function IsVowelChar(c: aChar): Boolean;
  Begin
    Result := SP_Util.Pos(c, 'AEIOU') > 0;
  End;

Begin
  Result := Nil;
  If Phonemes = '' Then Exit;

  // ---- Parse ----
  SetLength(Indices, Length(Phonemes) + 2);   // +2 allows room for PA1/PA2 injection
  SetLength(Stresses, Length(Phonemes) + 2);
  AlloCount := ParsePhonemes(Phonemes, Indices, Stresses);
  If AlloCount = 0 Then Exit;

  // Lead-in silence
  If AlloCount > 0 Then Begin
    Allo := AlloPhones[Indices[0]];
    If Allo.Voiced And Not IsVowelChar(aChar(Allo.Name[1])) Then Begin
      SetLength(Indices,  AlloCount + 1);
      SetLength(Stresses, AlloCount + 1);
      For i := AlloCount DownTo 1 Do Begin
        Indices[i]  := Indices[i - 1];
        Stresses[i] := Stresses[i - 1];
      End;
      Idx := SP_NarratorFindAllophone('PA1');
      If Idx >= 0 Then Begin
        Indices[0]  := Idx;
        Stresses[0] := 0; // silence has no stress
        Inc(AlloCount);
      End;
    End;
  End;

  // Lead-out silence
  If AlloCount > 0 Then Begin
    SetLength(Indices,  AlloCount + 1);
    SetLength(Stresses, AlloCount + 1);
    Idx := SP_NarratorFindAllophone('PA2');
    If Idx >= 0 Then Begin
      Indices[AlloCount]  := Idx;
      Stresses[AlloCount] := 0;
      Inc(AlloCount);
    End;
  End;
  SetLength(Indices,  AlloCount);
  SetLength(Stresses, AlloCount);

  // ---- Size ----
  RateScale := 150.0 / Max(1, Params.Rate);
  TotalSamples := 0;
  For ai := 0 To AlloCount - 1 Do Begin
    // Stress-level duration scale applies to voiced non-stop allophones only
    If AlloPhones[Indices[ai]].Voiced And Not AlloPhones[Indices[ai]].Stop Then Begin
      Case Stresses[ai] Of
        0: StressDurScale := 0.85;
        2: StressDurScale := 1.40;
      Else StressDurScale := 1.00;
      End;
    End Else
      StressDurScale := 1.00;
    TotalSamples := TotalSamples +
      Round(AlloPhones[Indices[ai]].DurMs * SP_NARRATOR_SAMPLERATE / 1000.0 * RateScale * StressDurScale);
  End;

  BufBytes := TotalSamples * 2 + 16;
  SetLength(Result, BufBytes);
  FillChar(Result[0], BufBytes, 0);

  // ---- Init state ----
  FillChar(State, SizeOf(State), 0);
  State.NoiseSeed := $DEADBEEF;
  CurEmph         := 0.96;

  For i := 1 To 4 Do Begin
    State.PrevF[i]  := AlloPhones[Indices[0]].F[i];
    State.PrevBW[i] := AlloPhones[Indices[0]].BW[i];
    InitFormant(State.Filters[i], AlloPhones[Indices[0]].F[i], AlloPhones[Indices[0]].BW[i], SP_NARRATOR_SAMPLERATE);
    State.Filters[i].Gain := 1.0 - State.Filters[i].A1 - State.Filters[i].A2;
  End;
  InitAntiResonator(State.NasalNotch, 1200, 200, SP_NARRATOR_SAMPLERATE);

  WritePos   := 0;
  PitchStart := Params.Pitch;
  PitchEnd   := Params.Pitch * 0.85;
  PitchHz    := PitchStart;
  FillChar(PrevAllo, SizeOf(PrevAllo), 0);

  // ---- Main allophone loop ----
  For ai := 0 To AlloCount - 1 Do Begin
    Allo := AlloPhones[Indices[ai]];
    AlloName := SP_Util.Upper(aString(Allo.Name));

    // If the target is Silence or a Glottal Stop (F1=0), do NOT sweep the
    // filters to 0 Hz! Freeze the mouth in its previous shape so the vowel
    // doesn't collapse into a "buh" or "thud".
    If (Allo.F[1] = 0) And (ai > 0) Then Begin
      For i := 1 To 4 Do Begin
        Allo.F[i]  := Round(State.PrevF[i]);
        Allo.BW[i] := Round(State.PrevBW[i]);
      End;
    End;

    StressLevel := Stresses[ai];

    // Stress parameters (voiced non-stop allophones only; pauses/stops unaffected)
    If Allo.Voiced And Not Allo.Stop Then Begin
      Case StressLevel Of
        0: Begin StressDurScale := 0.85; StressAmpScale := 0.82; StressPitchPeak := -8.0;  End;
        2: Begin StressDurScale := 1.40; StressAmpScale := 1.12; StressPitchPeak := +18.0; End;
      Else   Begin StressDurScale := 1.00; StressAmpScale := 1.00; StressPitchPeak := +6.0;  End;
      End;
    End Else Begin
      StressDurScale  := 1.00;
      StressAmpScale  := 1.00;
      StressPitchPeak := 0.0;
    End;

    BypassF1 := (Allo.Stop) Or ((Allo.NoiseAmp >= 0.10) And (AlloName <> 'HH'));

    If Allo.Stop And Not PrevAllo.Nasal Then Begin
      State.NasalNotch.X1 := 0;
      State.NasalNotch.X2 := 0;
    End;

    DurSamples := Round(Allo.DurMs * SP_NARRATOR_SAMPLERATE / 1000.0 * RateScale * StressDurScale);

    // Diphthongs must be calculated before PrevAllo.Stop so their glides aren't truncated!
    IsDiphthong := (AlloName = 'AY') Or (AlloName = 'AW') Or (AlloName = 'OY') Or
                   (AlloName = 'EY') Or (AlloName = 'OW');

    If Allo.Stop Then
      TransSamples := Max(1, DurSamples Div 5)
    Else If IsDiphthong Then
      TransSamples := Max(1, (DurSamples * 4) Div 5)  // Force slow 80% glide for all diphthongs
    Else If PrevAllo.Stop Then
      TransSamples := Max(1, DurSamples Div 4)
    Else If (Allo.DurMs >= 130) And Allo.Voiced And Not Allo.Nasal And Not Allo.Stop Then
      TransSamples := Max(1, (DurSamples * 4) Div 5)
    Else If Allo.NoiseAmp > Allo.BuzzAmp Then
      TransSamples := Max(1, DurSamples Div 4)
    Else
      TransSamples := Max(1, DurSamples Div 3);

    StopSamples := 0;
    If Allo.Stop Then Begin
      If Allo.Voiced Then
        StopSamples := (DurSamples * 3) Div 4
      Else
        StopSamples := (DurSamples * 2) Div 5;
    End;

    For i := 1 To 4 Do Begin
      SavePrevF[i]  := State.PrevF[i];
      SavePrevBW[i] := State.PrevBW[i];
    End;

    // Never sweep formants from 0 Hz (silence). Instantly assume the target locus.
    // This prevents massive DC thumps when starting words after pauses.
    If (PrevAllo.DurMs = 0) Or (PrevAllo.F[1] = 0) or (PrevAllo.Name = 'HH') Then Begin
      For i := 1 To 4 Do Begin
        SavePrevF[i]  := Allo.F[i];
        SavePrevBW[i] := Allo.BW[i];
      End;
    End;

    IsDiphthong := (AlloName = 'AY') Or (AlloName = 'AW') Or (AlloName = 'OY') Or
                   (AlloName = 'EY') Or (AlloName = 'OW');
    // Always force the correct phonetic onset for diphthongs.
    // The allophone table stores the ENDPOINT; without this block the synthesiser
    // inherits the preceding consonant's formants and the glide never happens.
    If IsDiphthong Then Begin
      If (AlloName = 'AY') Or (AlloName = 'AW') Then Begin
        SavePrevF[1]  := 730;  SavePrevF[2]  := 1090; SavePrevF[3]  := 2440; SavePrevF[4]  := 3850;
        SavePrevBW[1] := 70;   SavePrevBW[2] := 200;  SavePrevBW[3] := 250;  SavePrevBW[4] := 250;
      End Else If (AlloName = 'OY') Or (AlloName = 'OW') Then Begin
        SavePrevF[1]  := 570;  SavePrevF[2]  := 840;  SavePrevF[3]  := 2410; SavePrevF[4]  := 3850;
        SavePrevBW[1] := 60;   SavePrevBW[2] := 150;  SavePrevBW[3] := 250;  SavePrevBW[4] := 250;
      End Else If AlloName = 'EY' Then Begin
        SavePrevF[1]  := 530;  SavePrevF[2]  := 1840; SavePrevF[3]  := 2480; SavePrevF[4]  := 3850;
        SavePrevBW[1] := 60;   SavePrevBW[2] := 200;  SavePrevBW[3] := 250;  SavePrevBW[4] := 250;
      End;
      For i := 1 To 4 Do Begin
        State.PrevF[i]  := SavePrevF[i];
        State.PrevBW[i] := SavePrevBW[i];
      End;
    End;

    UpdateNoiseColour(State, Allo);

    AlloProgress := ai / Max(1, AlloCount - 1);
    If Allo.Voiced Then
      If Params.Mode = 0 Then PitchHz := PitchStart + (PitchEnd - PitchStart) * AlloProgress
      Else PitchHz := PitchStart;

    NextCoeffAt := 0;

    // ---- Per-sample loop ----
    For si := 0 To DurSamples - 1 Do Begin
      If WritePos >= BufBytes - 1 Then Break;

      If si >= NextCoeffAt Then Begin
        If TransSamples > 0 Then Progress := Min(1.0, si / TransSamples) Else Progress := 1.0;
        UpdateFormantCoeffs(State, Allo, Params, Progress, SavePrevF, SavePrevBW);
        NextCoeffAt := si + SP_NARRATOR_COEFF_INTERVAL;
        If Progress >= 1.0 Then NextCoeffAt := MaxInt;
      End;

      RawNoise := WhiteNoise(State.NoiseSeed);

      // Generate Pink Noise
      // A simple 1-pole lowpass filter that removes the harsh digital treble
      State.PinkNoiseX1 := State.PinkNoiseX1 * 0.75 + rawNoise * 0.25;

      AspPart  := 0;
      FricPart := 0;

      // ---- Stress pitch arc ----
      // Smooth rise-peak-fall over the allophone using a half-sine envelope.
      // Adds natural intonation peaks at primary-stressed vowels.
      If Allo.Voiced And (DurSamples > 0) Then Begin
        StressPitchArc := StressPitchPeak * Sin(Pi * si / DurSamples);
      End Else
        StressPitchArc := 0.0;

      // ---- Source ----
      // Stress amplitude: scale buzz source; clamp so we never exceed unity
      EffBuzzAmp := Allo.BuzzAmp * StressAmpScale;
      If EffBuzzAmp > 1.0 Then EffBuzzAmp := 1.0;

      If Allo.Stop Then Begin
        If si < StopSamples Then Begin
          // Closure phase smoothly fades into the muffled state over 10ms (preventing instant volume drop click)
          FadeLen := Min(441, StopSamples);
          If (si < FadeLen) And (FadeLen > 0) Then Begin
            ClosureFade := 1.0 - (si / FadeLen);
            PrevBuzz := PrevAllo.BuzzAmp;
            If PrevAllo.Stop Then PrevBuzz := PrevAllo.BuzzAmp * 0.02; // If previous was a stop, it was already muffled

            BuzzPart := GlottalBuzz(State.BuzzPhase, PitchHz + StressPitchArc, SP_NARRATOR_SAMPLERATE) *
                        (PrevBuzz * ClosureFade + EffBuzzAmp * 0.02 * (1.0 - ClosureFade));
          End Else Begin
            BuzzPart := GlottalBuzz(State.BuzzPhase, PitchHz + StressPitchArc, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp * 0.02;
          End;
        End Else Begin
          // Release phase
          BurstTime := si - StopSamples;

          // Voicing Ramp: Prevent instant volume snaps at the release point
          If (Allo.Voiced) And (BurstTime < 660) Then // 15ms ramp
            BuzzPart := GlottalBuzz(State.BuzzPhase, PitchHz + StressPitchArc, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp * (0.02 + 0.98 * (BurstTime / 660.0))
          Else
            BuzzPart := GlottalBuzz(State.BuzzPhase, PitchHz + StressPitchArc, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp;

          RawNoise := WhiteNoise(State.NoiseSeed); // Get a fresh random number
          FricPart := RawNoise * Allo.NoiseAmp;    // <-- MUST BE RAW NOISE, NOT PINK!

          If Allo.Voiced Then
            PlosiveLen := Round(0.015 * SP_NARRATOR_SAMPLERATE)
          Else
            PlosiveLen := Round(0.030 * SP_NARRATOR_SAMPLERATE);

          If PlosiveLen > (DurSamples - StopSamples) Then
            PlosiveLen := DurSamples - StopSamples;

          // Micro 1ms noise attack to prevent high-frequency digital tick
          If BurstTime < 44 Then
            NoiseAttack := BurstTime / 44.0
          Else
            NoiseAttack := 1.0;

          If (AlloName = 'CH') Or (AlloName = 'JH') Then Begin
            // Affricates don't pop and die; they sustain a strong "SH" friction!
            FricPart := RawNoise * NoiseAttack;
          End Else Begin
            // Normal Plosive burst (P, T, K, B, D, G)
            If BurstTime < PlosiveLen Then Begin
              If BurstTime < 220 Then Begin // 5ms initial transient
                BurstRamp := 1.0 - (BurstTime / 220.0);
                If Allo.Voiced Then
                  BurstEnv := 1.0 + 0.5 * BurstRamp
                Else
                  BurstEnv := 1.0 + 1.2 * BurstRamp;
                FricPart := FricPart * BurstEnv * NoiseAttack;
              End Else If (PlosiveLen > 220) Then Begin
                DecayRamp := 1.0 - ((BurstTime - 220) / (PlosiveLen - 220));
                FricPart := FricPart * (DecayRamp * DecayRamp * DecayRamp) * NoiseAttack;
              End Else Begin
                FricPart := 0;
              End;
            End Else Begin
              FricPart := 0;
            End;
          End;

        End;
      End Else Begin
        // Amplitude crossfade: blend BuzzAmp and NoiseAmp from the previous
        // allophone's values to this allophone's values over ~8 ms (353 samples).
        // Prevents pops at voiced<->unvoiced boundaries and fricative onsets.
        AmpFadeLen := Min(353, DurSamples Div 3);
        If (si < AmpFadeLen) And (AmpFadeLen > 0) Then
          AmpFade := si / AmpFadeLen
        Else
          AmpFade := 1.0;
        CurBuzzAmp  := PrevAllo.BuzzAmp  + (EffBuzzAmp    - PrevAllo.BuzzAmp)  * AmpFade;
        CurNoiseAmp := PrevAllo.NoiseAmp + (Allo.NoiseAmp - PrevAllo.NoiseAmp) * AmpFade;

        BuzzPart := GlottalBuzz(State.BuzzPhase, PitchHz + StressPitchArc, SP_NARRATOR_SAMPLERATE) * CurBuzzAmp;

        If AlloName = 'HH' Then Begin
          OnsetSamples := Round(0.025 * SP_NARRATOR_SAMPLERATE);
          If si < OnsetSamples Then NoiseScale := si / OnsetSamples Else NoiseScale := 1.0;
        End Else NoiseScale := 1.0;

        If BypassF1 Then
          FricPart := State.PinkNoiseX1 * CurNoiseAmp * NoiseScale
        Else
          AspPart := State.PinkNoiseX1 * CurNoiseAmp * NoiseScale;
      End;

      // ---- Filter cascade ----
      If BypassF1 Then Begin
        Filtered := ProcessFormant(State.Filters[1], BuzzPart);
        Filtered := ProcessFormant(State.Filters[2], Filtered);
        Filtered := ProcessFormant(State.Filters[3], Filtered);
        Filtered := ProcessFormant(State.Filters[4], Filtered);

        FricPart := ProcessFormant(State.NoiseFilter, FricPart) * 0.25;
        Filtered := Filtered + FricPart;
      End Else Begin
        TempFilter := ProcessFormant(State.Filters[1], BuzzPart + AspPart * 0.05);
        TempFilter := ProcessFormant(State.Filters[2], TempFilter);

        Filtered := ProcessFormant(State.Filters[3], TempFilter + (BuzzPart + AspPart * 0.05) * 0.05);
        Filtered := ProcessFormant(State.Filters[4], Filtered);
      End;

      If Allo.Nasal Then Filtered := ProcessAntiResonator(State.NasalNotch, Filtered);

      If Allo.Nasal Then TargetEmph := 0.70 Else TargetEmph := 0.96;
      CurEmph := CurEmph + (TargetEmph - CurEmph) * 0.005;

      FRaw           := Filtered;
      Filtered       := Filtered - CurEmph * State.BrightX1;
      State.BrightX1 := FRaw;

      If Filtered >  1.0 Then Filtered :=  1.0;
      If Filtered < -1.0 Then Filtered := -1.0;
      pSmallInt(@Result[WritePos])^ := Round(Filtered * 32767.0);
      Inc(WritePos, 2);
    End;

    For i := 1 To 4 Do Begin
      State.PrevF[i]  := Allo.F[i];
      State.PrevBW[i] := Allo.BW[i];
    End;
    PrevAllo := Allo;
  End;

  // ---- De-click: 5ms fade in/out ----
  DeClickLen := Min(Round(0.005 * SP_NARRATOR_SAMPLERATE), TotalSamples Div 4);
  For i := 0 To DeClickLen - 1 Do Begin
    Scale := i / DeClickLen;
    pSmallInt(@Result[i * 2])^ := Round(pSmallInt(@Result[i * 2])^ * Scale);
    pSmallInt(@Result[WritePos - (i + 1) * 2])^ := Round(pSmallInt(@Result[WritePos - (i + 1) * 2])^ * Scale);
  End;

  // Final Normalisation
  RMSSum := 0; SampleCount := 0; i := 0;
  While i < WritePos - 1 Do Begin
    RMSVal := pSmallInt(@Result[i])^;
    RMSSum := RMSSum + RMSVal * RMSVal;
    Inc(SampleCount); Inc(i, 2);
  End;

  If SampleCount > 0 Then Begin
    RMSVal := Sqrt(RMSSum / SampleCount);
    If RMSVal > 0 Then Begin
      Scale := (32767.0 * 0.80) / (RMSVal * 2.0);
      i := 0;
      While i < WritePos - 1 Do Begin
        ClampedS := Round(pSmallInt(@Result[i])^ * Scale);
        If ClampedS >  32767 Then ClampedS :=  32767;
        If ClampedS < -32768 Then ClampedS := -32768;
        pSmallInt(@Result[i])^ := ClampedS;
        Inc(i, 2);
      End;
    End;
  End;

End;

Procedure SP_Say(Const Phonemes: aString;
                 Const Params:   TNarratorParams;
                       Async:    Boolean);
Var
  Buf:     TBytes;
  Sample:  HSAMPLE;
  Channel: HCHANNEL;
  BufSize: Integer;
  Speech:  aString;
Begin
  If Not SoundEnabled Then Exit;
  If Phonemes = '' Then Exit;

  If SP_IsAmigaSpeech(Phonemes) Then
    Speech := SP_NarratorFromAmiga(Phonemes)
  Else
    Speech := Phonemes;

  Buf := SP_NarratorSynth(Speech, Params);
  If Buf = Nil Then Exit;

  BufSize := Length(Buf);
  If BufSize < 2 Then Exit;

  Sample := BASS_SampleCreate(BufSize, SP_NARRATOR_SAMPLERATE, 1, 1, BASS_SAMPLE_OVER_POS);
  If Sample = 0 Then Exit;

  BASS_SampleSetData(Sample, @Buf[0]);

  Channel := BASS_SampleGetChannel(Sample, False);
  BASS_ChannelSetAttribute(Channel, BASS_ATTRIB_VOL, Params.Volume);
  BASS_ChannelPlay(Channel, True);

  If Async Then Begin
    BEEPMonitor.AddChannel(Channel, Sample);
  End Else Begin
    While (BASS_ChannelIsActive(Channel) = BASS_ACTIVE_PLAYING) And (KEYSTATE[K_Escape] = 0) Do
      CB_YIELD(1);
    If KEYSTATE[K_Escape] = 1 Then BREAKSIGNAL := True;
    BASS_SampleFree(Sample);
  End;
End;

end.
