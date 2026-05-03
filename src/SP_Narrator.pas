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
  SP_NARRATOR_ALLOPHONE_COUNT = 57;

  // Default parameter values - male voice
  SP_NARRATOR_DEFAULT_PITCH        = 120;   // Hz - natural male voice neutral pitch
  SP_NARRATOR_DEFAULT_PITCH_FEMALE = 210;   // Hz - suggested female voice pitch
                                            // Set Params.Pitch to this when Sex=1.
                                            // Both voices now use full prosody (declination,
                                            // Hat, stress arcs) anchored at Params.Pitch.
  SP_NARRATOR_DEFAULT_RATE   = 150;   // nominal words/min scale (Amiga range 1..400)
  SP_NARRATOR_DEFAULT_SEX    = 0;     // 0=male, 1=female
  SP_NARRATOR_DEFAULT_MODE   = 0;     // 0=natural, 1=robotic
  SP_NARRATOR_DEFAULT_VOLUME = 1.0;

  // Amiga pitch model constants.
  // SP_AMIGA_REFERENCE_PITCH is retained as documentation of the Amiga's
  // Paula default period (0xA0 = 160 samples at 22254 Hz = 139 Hz).
  // Duration is calibrated to this value in the DurMs table but is no longer
  // coupled to Params.Pitch at runtime — see ComputeDurSamples.
  SP_AMIGA_REFERENCE_PITCH   = 139.0; // Hz — Amiga Paula period=160 at 22254 Hz
  SP_NARRATOR_WFL_SCALE      = 1.20;  // word-final lengthening factor

  // Coefficient update interval - recalculate filter coefficients every N samples.
  // 220 samples ≈ 5 ms at 44100 Hz; smooth enough, cheap enough.
  SP_NARRATOR_COEFF_INTERVAL = 220;

Type

  TNarratorParams = Record
    Pitch:  Integer;   // fundamental frequency Hz, 65..320
    Rate:   Integer;   // duration scale, 65..400 (150 = normal)
    Sex:    Integer;   // 0=male, 1=female
    Mode:   Integer;   // 0=natural, 1=robotic (flat pitch)
    Volume: Single;    // 0..1
  End;

  TAlloPhone = Record
    Name:           String[4];
    DurMs:          Integer;      // stressed duration ms at Amiga reference pitch 139 Hz / Rate=150
    UnstressedDurMs:Integer;      // unstressed duration ms (Amiga two-table; ~1/3 of DurMs for vowels)
    F:        Array[1..4] of Integer;   // formant centre frequencies Hz
    BW:       Array[1..4] of Integer;   // formant bandwidths Hz
    BuzzAmp:  Single;              // voiced source level 0..1
    NoiseAmp: Single;              // noise source level 0..1
    Voiced:   Boolean;
    Nasal:    Boolean;
    Stop:     Boolean;             // closure+burst behaviour
  End;

  TFormantFilter = Record
    A1, A2: Double;       // IIR feedback coefficients
    Gain:   Double;       // output normalisation
    Y1, Y2: Double;       // delay-line state
  End;

  // Anti-resonator for nasals - same structure, different meaning
  TAntiResonator = Record
    A1, A2: Double;
    Gain:   Double;   // DC normalisation: 1/(1-A1-A2) keeps unity gain outside the notch
    X1, X2: Double;   // feed-forward delay (uses input history, not output)
  End;

  // Pre-computed Liljencrants-Fant glottal model parameters.
  // Recalculated once per allophone via UpdateLFParams; used per-sample in LFGlottalPulse.
  //
  // The LF model parametrises the derivative of glottal airflow dEg/dt:
  //   Open phase  [0, Te]:    E0 * exp(Alpha*phi) * sin(OmegaG*phi)
  //   Return phase [Te, 1]:   EeVal * [exp(-(phi-Te)/Ta) - exp(-(1-Te)/Ta)]
  //                           / [1 - exp(-(1-Te)/Ta)]
  //
  // The Rd parameter maps to voice quality:
  //   Rd = 0.5  — pressed/creaky (bright harmonics, tight larynx)
  //   Rd = 1.0  — modal voice (natural male speech)
  //   Rd = 2.0  — breathy (softer closure, darker spectrum)
  //   Rd is driven from stress level so stressed syllables are slightly more pressed.
  TLFState = Record
    E0:     Double;   // open-phase amplitude normalisation (peak -> 1.0)
    Alpha:  Double;   // open-phase spectral tilt (negative -> darker with higher Rd)
    OmegaG: Double;   // = Pi/Tp; open-phase angular frequency
    Te:     Double;   // end of open phase (fraction of period)
    Ta:     Double;   // return-phase time constant (fraction of period)
    EeVal:  Double;   // value of open-phase function at Te (return phase starts here)
    TailDenom: Double;// 1 - exp(-(1-Te)/Ta); precomputed for return-phase formula
  End;

  // Internal state passed through the synthesis loop
  TSynthState = Record
    Filters:      Array[1..4] of TFormantFilter;
    NasalNotch:   TAntiResonator;
    BuzzPhase:    Double;    // phase accumulator for glottal pulse, 0..1
    NoiseSeed:    LongWord;  // LCG state
    JitterSeed:   LongWord;  // separate LCG for pitch jitter (keeps noise uncorrelated)
    PrevF:        Array[1..4] of Double;  // formant freqs at end of last allophone
    PrevBW:       Array[1..4] of Double;  // bandwidths at end of last allophone
    PreEmphX1:    Double;
    NoiseFilter:  TFormantFilter;
    BrightX1:     Double;
    PinkNoiseX1:  Double;
    LF:           TLFState;  // LF glottal model; updated each allophone by UpdateLFParams
  End;

Const

  // -----------------------------------------------------------------------
  // Allophone table - 59 entries, index 0..58
  // Formant frequencies and bandwidths from phonetic literature tuned to
  // approximate the Amiga Narrator.device male voice characteristic.
  // -----------------------------------------------------------------------

  AlloPhones: Array[0..SP_NARRATOR_ALLOPHONE_COUNT - 1] of TAlloPhone = (

    // --- Vowels ---
    // DurMs = Amiga stressed table; UnstressedDurMs = Amiga unstressed table (ratio ~3:1)
    (Name:'IY';  DurMs:137; UnstressedDurMs: 43; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'IH';  DurMs:129; UnstressedDurMs: 43; F:(390,1990,2550,3850); BW:(50,200,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'EH';  DurMs:129; UnstressedDurMs: 50; F:(530,1840,2480,3850); BW:(60,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AE';  DurMs:180; UnstressedDurMs: 50; F:(660,1720,2410,3850); BW:(70,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AA';  DurMs:173; UnstressedDurMs: 72; F:(730,1090,2440,3850); BW:(70,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AH';  DurMs:122; UnstressedDurMs: 43; F:(640,1190,2390,3850); BW:(70,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AO';  DurMs:209; UnstressedDurMs: 72; F:(570, 840,2410,3850); BW:(60,150,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'OW';  DurMs:187; UnstressedDurMs: 58; F:(360, 640,2390,3850); BW:(50,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'UH';  DurMs:137; UnstressedDurMs: 43; F:(440,1020,2240,3850); BW:(50,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'UW';  DurMs:158; UnstressedDurMs: 50; F:(300, 870,2240,3850); BW:(40,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'ER';  DurMs:158; UnstressedDurMs: 50; F:(490,1350,1690,3850); BW:(70,150,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AX';  DurMs:101; UnstressedDurMs: 36; F:(500,1500,2500,3850); BW:(80,200,250,250); BuzzAmp:0.60; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),

    // --- Diphthongs (onset formants forced in the main loop; target = endpoint) ---
    (Name:'AY';  DurMs:209; UnstressedDurMs: 79; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'AW';  DurMs:223; UnstressedDurMs: 86; F:(300, 870,2240,3850); BW:(40,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'OY';  DurMs:245; UnstressedDurMs: 94; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'EY';  DurMs:165; UnstressedDurMs: 58; F:(270,2290,3010,3850); BW:(45,200,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),

    // --- Semivowels / liquids ---
    (Name:'WW';  DurMs: 72; UnstressedDurMs: 50; F:(290, 610,2150,3850); BW:(40, 60,250,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),
    (Name:'RR';  DurMs: 72; UnstressedDurMs: 29; F:(490,1350,1690,3850); BW:(60,100,200,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),
    (Name:'LL';  DurMs: 72; UnstressedDurMs: 36; F:(310,1050,2880,3850); BW:(40,150,250,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),
    (Name:'YY';  DurMs: 72; UnstressedDurMs: 36; F:(280,2250,3070,3850); BW:(40,200,250,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),

    // --- Nasals ---
    (Name:'MM'; DurMs: 72; UnstressedDurMs: 50; F:(270, 900,2000,3300); BW:(350,500,600,400); BuzzAmp:0.55; NoiseAmp:0.05; Voiced:True; Nasal:True; Stop:False),
    (Name:'NN'; DurMs: 80; UnstressedDurMs: 60; F:(250,1400,2600,3300); BW:(350,500,600,400); BuzzAmp:0.55; NoiseAmp:0.05; Voiced:True; Nasal:True; Stop:False),
    (Name:'NX'; DurMs: 72; UnstressedDurMs: 43; F:(250,2200,2600,3300); BW:(350,500,600,400); BuzzAmp:0.55; NoiseAmp:0.05; Voiced:True; Nasal:True; Stop:False),

    // --- Unvoiced fricatives ---
    (Name:'FF'; DurMs:101; UnstressedDurMs: 50; F:(900,1220,2090,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.25; Voiced:False; Nasal:False; Stop:False),
    (Name:'TH'; DurMs: 94; UnstressedDurMs: 36; F:(900,1480,2500,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.30; Voiced:False; Nasal:False; Stop:False),
    (Name:'SS'; DurMs:108; UnstressedDurMs: 43; F:(900,2250,3200,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.90; Voiced:False; Nasal:False; Stop:False),
    (Name:'SH'; DurMs:108; UnstressedDurMs: 43; F:(900,1750,2800,3850); BW:(200,200,250,250); BuzzAmp:0.00; NoiseAmp:0.85; Voiced:False; Nasal:False; Stop:False),
    (Name:'HH'; DurMs: 89; UnstressedDurMs: 65; F:(900,1200,2500,3500); BW:(400,400,300,300); BuzzAmp:0.00; NoiseAmp:0.55; Voiced:False; Nasal:False; Stop:False),

    // --- Voiced fricatives ---
    (Name:'VV'; DurMs: 65; UnstressedDurMs: 43; F:(280,1220,2090,3850); BW:(40,200,250,250); BuzzAmp:0.50; NoiseAmp:0.20; Voiced:True;  Nasal:False; Stop:False),
    (Name:'DH'; DurMs: 43; UnstressedDurMs: 29; F:(280,1480,2500,3850); BW:(40,200,250,250); BuzzAmp:0.20; NoiseAmp:0.25; Voiced:True;  Nasal:False; Stop:False),
    (Name:'ZZ'; DurMs: 58; UnstressedDurMs: 36; F:(280,2250,2800,3850); BW:(40,200,250,250); BuzzAmp:0.50; NoiseAmp:0.60; Voiced:True;  Nasal:False; Stop:False),
    (Name:'ZH'; DurMs: 58; UnstressedDurMs: 36; F:(280,1750,2480,3850); BW:(40,200,250,250); BuzzAmp:0.50; NoiseAmp:0.50; Voiced:True;  Nasal:False; Stop:False),

    // --- Affricates ---
    (Name:'CH'; DurMs: 72; UnstressedDurMs: 50; F:(400,1750,2480,3850); BW:(300,200,250,250); BuzzAmp:0.00; NoiseAmp:0.85; Voiced:False; Nasal:False; Stop:True),
    (Name:'JH'; DurMs: 58; UnstressedDurMs: 43; F:(400,1750,2480,3850); BW:(300,200,250,250); BuzzAmp:0.40; NoiseAmp:0.70; Voiced:True;  Nasal:False; Stop:True),

    // --- Unvoiced stops ---
    (Name:'PP'; DurMs:115; UnstressedDurMs: 65; F:(400, 600,2050,3850); BW:(150,100,250,250); BuzzAmp:0.00; NoiseAmp:0.35; Voiced:False; Nasal:False; Stop:True),
    (Name:'TT'; DurMs:108; UnstressedDurMs: 65; F:(400,1750,2600,3850); BW:(300,200,250,250); BuzzAmp:0.00; NoiseAmp:0.70; Voiced:False; Nasal:False; Stop:True),
    (Name:'KK'; DurMs:115; UnstressedDurMs: 65; F:(400,1990,2850,3850); BW:(300,200,250,250); BuzzAmp:0.00; NoiseAmp:0.70; Voiced:False; Nasal:False; Stop:True),

    // --- Voiced stops ---
    (Name:'BB'; DurMs: 86; UnstressedDurMs: 58; F:(400,600,2050,3850);  BW:(150,100,250,250); BuzzAmp:0.50; NoiseAmp:0.55; Voiced:True;  Nasal:False; Stop:True),
    (Name:'DD'; DurMs: 72; UnstressedDurMs: 50; F:(400,1750,2600,3850); BW:(300,200,250,250); BuzzAmp:0.50; NoiseAmp:0.35; Voiced:True;  Nasal:False; Stop:True),
    (Name:'GG'; DurMs: 72; UnstressedDurMs: 58; F:(400,1990,2850,3850); BW:(300,200,250,250); BuzzAmp:0.50; NoiseAmp:0.30; Voiced:True;  Nasal:False; Stop:True),

    // --- Flap ---
    (Name:'DX';  DurMs: 29; UnstressedDurMs: 14; F:(490,1350,1690,3850); BW:(70,150,200,250); BuzzAmp:0.85; NoiseAmp:0.10; Voiced:True;  Nasal:False; Stop:False),

    // --- Additional Amiga allophones ---
    // IX is always stress-level 0 (like AX); UnstressedDurMs is always used.
    (Name:'IX';  DurMs:101; UnstressedDurMs: 36; F:(430,1700,2550,3850); BW:(60,200,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'OH';  DurMs:158; UnstressedDurMs: 58; F:(480, 760,2400,3850); BW:(50,150,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'WH';  DurMs: 86; UnstressedDurMs: 50; F:(290, 610,2150,3850); BW:(40, 60,250,250); BuzzAmp:0.70; NoiseAmp:0.08; Voiced:True;  Nasal:False; Stop:False),
    (Name:'RX';  DurMs: 80; UnstressedDurMs: 40; F:(450,1300,1600,3850); BW:(60,100,200,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'LX';  DurMs: 80; UnstressedDurMs: 40; F:(400, 850,2700,3850); BW:(50,100,250,250); BuzzAmp:0.85; NoiseAmp:0.05; Voiced:True;  Nasal:False; Stop:False),
    (Name:'UL';  DurMs: 80; UnstressedDurMs: 50; F:(400, 900,2700,3850); BW:(50,150,250,250); BuzzAmp:0.85; NoiseAmp:0.08; Voiced:True;  Nasal:False; Stop:False),
    (Name:'UN';  DurMs: 120;UnstressedDurMs: 90; F:(250,1400,2600,3300); BW:(150,300,400,350);BuzzAmp:0.50; NoiseAmp:0.05; Voiced:True;  Nasal:True;  Stop:False),
    (Name:'KH';  DurMs: 86; UnstressedDurMs: 36; F:(400,1990,2850,3850); BW:(200,300,300,300);BuzzAmp:0.00; NoiseAmp:0.80; Voiced:False; Nasal:False; Stop:False),
    (Name:'QQ';  DurMs: 30; UnstressedDurMs: 20; F:(0,0,0,0);            BW:(0,0,0,0);        BuzzAmp:0.00; NoiseAmp:0.00; Voiced:False; Nasal:False; Stop:True),
    (Name:'QX';  DurMs: 80; UnstressedDurMs: 50; F:(0,0,0,0);            BW:(0,0,0,0);        BuzzAmp:0.00; NoiseAmp:0.00; Voiced:False; Nasal:False; Stop:False),

    // --- Pauses ---
    // Durations are symmetric (stress level irrelevant for silence).
    // PA3 = Amiga sentence-boundary pause = 259 ms decoded from duration table index 1.
    (Name:'PA0'; DurMs:  5; UnstressedDurMs:  5; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA1'; DurMs: 10; UnstressedDurMs: 10; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA2'; DurMs:150; UnstressedDurMs:150; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA3'; DurMs:260; UnstressedDurMs:260; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA4'; DurMs:100; UnstressedDurMs:100; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False),
    (Name:'PA5'; DurMs:200; UnstressedDurMs:200; F:(0,0,0,0); BW:(0,0,0,0); BuzzAmp:0.0; NoiseAmp:0.0; Voiced:False; Nasal:False; Stop:False)
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
  If DC <> 0 Then A.Gain := 0.6 / DC Else A.Gain := 0.6;
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

// UpdateLFParams
//   Pre-computes the Liljencrants-Fant glottal model parameters for a given
//   voice quality level Rd.  Called once per allophone change; the results are
//   stored in State.LF and used sample-by-sample by LFGlottalPulse.
//
// Physical interpretation of Rd:
//   Open phase  -> positive lobe (glottis opening)
//   Closure     -> negative spike at Te (main vocal-tract excitation)
//   Return phase-> exponential recovery to zero baseline
//
// Rd -> model parameters mapping (after Fant 1994, Table 1):
//   Oq (open quotient) = Te = 0.50 + 0.15 * Rd  [clamped 0.38..0.90]
//   Tp (time to +lobe peak) = Te / 1.55           [fixed asymmetry Rk=0.55]
//   Alpha (spectral tilt)  = -(0.3 + 0.6*Rd)/Te  [negative -> darker @ high Rd]
//   Ta (return time const) = max(0.003, 0.016*Rd)
//
Procedure UpdateLFParams(Var State: TSynthState; Rd: Double);
Var
  Te, Tp, Ta, Alpha, OmegaG: Double;
  PhiPeak, PeakAmp:           Double;
  TailLength:                 Double;
Begin
  // Map Rd to physical parameters
  Te     := Min(Max(0.50 + 0.15 * Rd, 0.38), 0.90);
  Tp     := Te / 1.55;
  Ta     := Max(0.003, 0.016 * Rd);
  Alpha  := -(0.30 + 0.60 * Rd) / Te;
  OmegaG := Pi / Tp;

  // Peak of open phase (positive lobe): solve d/dphi[exp(Alpha*phi)*sin(OmegaG*phi)] = 0
  //   tan(OmegaG*phi_peak) = -OmegaG/Alpha
  //   phi_peak = ArcTan(-OmegaG/Alpha) / OmegaG
  // Alpha < 0 -> -OmegaG/Alpha > 0 -> ArcTan returns value in (0, Pi/2) ✓
  PhiPeak := ArcTan(-OmegaG / Alpha) / OmegaG;
  PeakAmp := Exp(Alpha * PhiPeak) * Sin(OmegaG * PhiPeak);
  If Abs(PeakAmp) > 1e-12 Then
    State.LF.E0 := 1.0 / PeakAmp
  Else
    State.LF.E0 := 1.0;

  // Value at Te: starting point of the return phase (the closure spike)
  State.LF.EeVal := State.LF.E0 * Exp(Alpha * Te) * Sin(OmegaG * Te);

  // Return-phase denominator: 1 - exp(-(1-Te)/Ta)
  // This normalises the return phase so that it starts at EeVal and
  // asymptotically approaches zero at phi = 1 (end of cycle).
  TailLength           := 1.0 - Te;
  State.LF.TailDenom   := 1.0 - Exp(-TailLength / Ta);
  If State.LF.TailDenom < 1e-10 Then State.LF.TailDenom := 1e-10;

  State.LF.Alpha  := Alpha;
  State.LF.OmegaG := OmegaG;
  State.LF.Te     := Te;
  State.LF.Ta     := Ta;
End;

// LFGlottalPulse
//   Computes the LF model glottal flow DERIVATIVE (dEg/dt) for one sample,
//   and advances the phase accumulator by one sample period.
//
//   The derivative (not the flow itself) is used because:
//   (a) it provides the correct spectral slope input for the formant cascade;
//   (b) it contains the sharp negative closure spike that excites high harmonics.
//
//   The positive lobe (opening phase) provides a smooth, lower-energy onset.
//   The negative closure spike at phi ≈ Te is the primary formant excitation.
//   The exponential return phase provides a gradual recovery, adding breathiness
//   whose magnitude is controlled by Ta (hence by Rd).
//
Function LFGlottalPulse(Var Phase: Double; Const LF: TLFState;
                         PitchHz, SR: Double): Double;
Var
  phi:       Double;
  TailScale: Double;
Begin
  phi := Phase;

  If phi < LF.Te Then Begin
    // Open phase: E0 * exp(Alpha*phi) * sin(OmegaG*phi)
    Result := LF.E0 * Exp(LF.Alpha * phi) * Sin(LF.OmegaG * phi);
  End Else Begin
    // Return phase: exponential recovery from EeVal toward zero.
    // Guard Ta > 0 so a zero-initialised LF state can never produce NaN.
    If (LF.Ta > 0) And (LF.TailDenom > 0) Then Begin
      TailScale := (Exp(-(phi - LF.Te) / LF.Ta) - Exp(-(1.0 - LF.Te) / LF.Ta))
                   / LF.TailDenom;
      Result := LF.EeVal * TailScale;
    End Else
      Result := 0.0;
  End;

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
  Else If Name = 'KH' Then
    InitFormant(State.NoiseFilter, 2200, 500, SP_NARRATOR_SAMPLERATE)
  Else If Name = 'WH' Then
    // WH now routes through the main formant cascade (BypassF1=False since
    // NoiseAmp=0.08 < 0.10).  This entry is a fallback in case that changes.
    InitFormant(State.NoiseFilter, 500, 2000, SP_NARRATOR_SAMPLERATE)
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

Procedure UpdateFormantCoeffs(Var State:       TSynthState;
                              Const CurAllo:   TAlloPhone;
                              Const Params:    TNarratorParams;
                                    Progress:  Double;
                              Const PrevF:     Array of Double;
                              Const PrevBW:    Array of Double;
                                    StressLvl: Integer);
Var
  i: Integer;
  TargF, TargBW, CurF, CurBW: Double;
  SexScale: Double;
  BWScale:  Double;
  SchwaBlend: Double;
Const
  SchwaF: Array[1..4] of Double = (500.0, 1500.0, 2500.0, 3850.0);
Begin
  If Params.Sex = 1 Then SexScale := 1.17 Else SexScale := 1.0;

  If CurAllo.Stop Then
    BWScale := 0.85
  Else If CurAllo.Nasal Then
    BWScale := 0.90
  Else If CurAllo.NoiseAmp > CurAllo.BuzzAmp Then
    BWScale := 0.85
  Else
    BWScale := 1.00;

  // Vowel reduction blend factor
  If CurAllo.Voiced And Not CurAllo.Nasal And Not CurAllo.Stop Then Begin
    Case StressLvl Of
      4: SchwaBlend := 0.15;
      0: SchwaBlend := 0.40;
    Else SchwaBlend := 0.0;
    End;
  End Else
    SchwaBlend := 0.0;

  For i := 1 To 4 Do Begin
    TargF  := CurAllo.F[i];
    // F1 benefits from tighter bandwidth for clearer vowel identity.
    // F2-F4 use the full tabulated bandwidth.
    If (i = 1) And CurAllo.Voiced And Not CurAllo.Stop And Not CurAllo.Nasal Then
      TargBW := CurAllo.BW[i] * 0.75
    Else
      TargBW := CurAllo.BW[i] * BWScale;

    If i = 3 Then TargF := TargF * 1.07
    Else If i = 4 Then TargF := TargF * 1.05;

    If Params.Sex = 1 Then Begin
      If i = 1 Then TargF := TargF * 1.10
      Else TargF := TargF * SexScale;
    End;

    // Pull toward schwa for weak/unstressed vowels
    If SchwaBlend > 0.0 Then
      TargF := TargF * (1.0 - SchwaBlend) + SchwaF[i] * SchwaBlend;

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

  If CurAllo.Nasal Then Begin
    If aString(CurAllo.Name) = 'MM' Then
      InitAntiResonator(State.NasalNotch, 850, 200, SP_NARRATOR_SAMPLERATE)
    Else If aString(CurAllo.Name) = 'NX' Then
      InitAntiResonator(State.NasalNotch, 1450, 200, SP_NARRATOR_SAMPLERATE)
    Else
      InitAntiResonator(State.NasalNotch, 1150, 200, SP_NARRATOR_SAMPLERATE);
  End;
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
  If Upper = 'UM' Then Upper := 'UN';  // syllabic M -> treat as syllabic N
  If Upper = 'IL' Then Upper := 'UL';  // IL variant -> UL
  If Upper = 'IN' Then Upper := 'UN';  // IN variant -> UN

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

    StressDigit := 4; // default = neutral if no digit present

    // Try the token as-is first (handles pause allophones PA0..PA5 whose
    // digit is part of the name, not a stress level marker).
    // Only strip trailing digits if the full token is not recognised.
    Idx := SP_NarratorFindAllophone(Token);
    If Idx < 0 Then Begin
      While (Length(Token) > 0) And (Token[Length(Token)] In ['0'..'9']) Do Begin
        StressDigit := Ord(Token[Length(Token)]) - Ord('0');
        Token := Copy(Token, 1, Length(Token) - 1);
      End;
      If StressDigit > 5 Then StressDigit := 5;
      Idx := SP_NarratorFindAllophone(Token);
    End;
    If (Idx >= 0) And (Count < Length(Indices)) Then Begin
      Indices[Count] := Idx;
      // Schwa (AX) and reduced vowel (IX) are inherently unstressed —
      // the Amiga translator never inserts a stress digit for them.
      // Force level 0 regardless of what the rules said.
      If (Token = 'AX') Or (Token = 'IX') Then
        Stresses[Count] := 0
      Else
        Stresses[Count] := StressDigit;
      Inc(Count);
    End;
  End;

  Result := Count;
End;

// ---------------------------------------------------------------------------
// Pitch and duration helpers
// ---------------------------------------------------------------------------
//
// ComputePitchHz
//   Returns the fundamental frequency Hz for a single allophone given its
//   stress level and the current voice parameters.
//
//   The Amiga pitch model (FUN_002211b8):
//     - All pitch-buffer slots initialise to period 0xA0 = 160 at 22254 Hz = 139 Hz.
//     - Non-stressed phonemes receive no pitch write -> stay at 139 Hz (1.00×).
//     - Stressed (level 1) phonemes fall to ~134 Hz (0.964×) — British nuclear fall.
//     - Very unstressed / schwa can rise to ~178 Hz (1.28×).
//   We use Params.Pitch as the NEUTRAL anchor (Amiga 139 Hz ≡ our Params.Pitch).
//   Stressed fall and unstressed rise are expressed as fixed ratios of that anchor.
//
Function ComputePitchHz(Const Allo:       TAlloPhone;
                              StressLevel: Integer;
                        Const Params:     TNarratorParams;
                              BoundaryPre: Integer): Double;
Begin
  // Robotic mode: flat pitch throughout, both male and female
  If Params.Mode = 1 Then Begin
    Result := Params.Pitch;
    Exit;
  End;
  // Unvoiced / stop: pitch has no perceptual effect — return anchor unchanged
  If (Not Allo.Voiced) Or Allo.Stop Then Begin
    Result := Params.Pitch;
    Exit;
  End;
  // Stress-based pitch (Amiga clamp 134–178 Hz relative to 139 Hz base):
  //   Level  Amiga ratio  Our value
  //   -----  -----------  ---------
  //   5 (emphatic fall)   0.935     strong nuclear fall
  //   1 (primary)         0.964     nuclear fall (Amiga: 134/139)
  //   2 (secondary)       0.980     modest fall
  //   3 (tertiary)        1.000     neutral
  //   4 (neutral)         1.000     neutral (Amiga: no write, stays at 139 Hz)
  //   0 (schwa)           1.280     high unstressed (Amiga: 178/139)
  Case StressLevel Of
    5: Result := Params.Pitch * 1.08;    // emphatic onset (will arc to ~0.90 trough)
    1: Result := Params.Pitch * 1.04;    // primary onset (will arc down to ~0.964 trough)
    2: Result := Params.Pitch * 1.02;    // secondary onset (will arc to ~0.980 trough)
    3: Result := Params.Pitch * 1.00;    // tertiary — neutral
    4: Result := Params.Pitch * 1.00;    // neutral — Amiga default, no pitch write
  Else
    Result := Params.Pitch * 1.28;       // schwa / fully unstressed (Amiga 178 Hz ceiling)
  End;
  // Phrase-boundary tones.
  // The Amiga unconditionally writes a terminal rise at utterance end
  // (FUN_00220a8e: pitch_buffer[last_slot+7] = base_unit / bank0[0xFF]).
  Case BoundaryPre Of
    2: Result := Result * 1.15;          // continuation rise (comma)
    3: Result := Result * 1.30;          // strong terminal rise (sentence end)
  End;
End;

// ComputeDurSamples
//   Converts a duration from the allophone table into PCM sample count.
//
//   Duration is taken directly from the Amiga two-table system (stressed /
//   unstressed) calibrated at the Amiga reference pitch of 139 Hz.  The
//   pitch-duration coupling (DurMs × 139 / PitchHz) that appeared in earlier
//   versions has been removed: it was a Paula DMA hardware artifact (one pass
//   of the waveform table = one glottal cycle at whatever period the hardware
//   was set to).  Our IIR synthesiser has no such constraint, and removing the
//   coupling means Params.Pitch can be set freely without changing speech rate.
//
//   WFL (word-final lengthening): the last voiced non-stop allophone before
//   any phrase boundary is stretched by SP_NARRATOR_WFL_SCALE (1.20).
//
//   ContextScale: caller-supplied multiplier applied after WFL, used for
//   pre-fortis clipping (≈ 0.68 before voiceless stops p/t/k).
//
Function ComputeDurSamples(Const Allo:        TAlloPhone;
                                 StressLevel:  Integer;
                                 RateScale:    Double;
                                 WFL:          Boolean;
                                 ContextScale: Double): Integer;
Var
  BaseDurMs: Integer;
Begin
  If StressLevel = 0 Then
    BaseDurMs := Allo.UnstressedDurMs
  Else
    BaseDurMs := Allo.DurMs;

  Result := Round(BaseDurMs * SP_NARRATOR_SAMPLERATE / 1000.0 * RateScale);

  If WFL And Allo.Voiced And Not Allo.Stop Then
    Result := Round(Result * SP_NARRATOR_WFL_SCALE);

  If ContextScale <> 1.0 Then
    Result := Max(1, Round(Result * ContextScale));
End;

// BuildF0Contour
//   Pre-computes a fundamental frequency value for every allophone in the
//   utterance and stores it in F0Contour[0..AlloCount-1].
//
//   The Amiga computes pitch slot-by-slot from divisor banks, producing a
//   piecewise-linear contour between stressed positions (FUN_0022120c).
//   We can do better: a proper prosodic model with phrase-level declination
//   and a nuclear Hat pattern gives more natural English intonation while
//   remaining faithful to the British nuclear-fall profile documented in the
//   Amiga annotations.
//
//   Model (one phrase at a time):
//     1. Declination: F0 falls linearly from TopLine (1.06 × anchor) to
//        BaseLine (0.94 × anchor) over the voiced duration of the phrase.
//        Matches British English phrase-level F0 fall.
//
//     2. Nuclear Hat: the most prominent stressed vowel (first level-1 or
//        level-5 vowel per phrase) receives a rise-fall overlay:
//          - Pre-nuclear rise: +12% above local declination line, peaking
//            one allophone before the nuclear vowel.
//          - Nuclear fall: the nuclear vowel itself sits at the local
//            declination value (the "fall" in the nuclear fall-rise).
//          - The hat shape is a half-cosine arc centred on the nuclear vowel.
//
//     3. Unstressed reduction: non-nuclear allophones are pulled toward the
//        local declination line (ComputePitchHz already did per-allophone
//        stress adjustment; here we smooth that with phrase context).
//
//     4. Boundary tones: the last voiced allophone before a PA2/PA3 boundary
//        receives the terminal contour (rise for comma, strong rise for '.')
//        already encoded in AlloBoundaryPre.
//
//   All values in Hz.  The per-sample pitch arc (StressPitchArc) is applied
//   ON TOP of these contour values to add intra-allophone shaping.
//
Procedure BuildF0Contour(Const Indices:      Array of Integer;
                          Const Stresses:     Array of Integer;
                                AlloCount:    Integer;
                          Const Params:       TNarratorParams;
                          Const BoundaryPre:  Array of Integer;
                          Var   F0Contour:    Array of Double);
Const
  TopLineMult  = 1.06;  // phrase onset F0 (above anchor)
  BaseLineMult = 0.94;  // phrase end F0 (declination floor, before boundary tone)
  HatRise      = 0.07;  // nuclear hat peak above local declination line (+7%)
  HatSpan      = 4;     // allophones either side of nucleus affected by the hat
Var
  ai:           Integer;
  PhraseStart:  Integer;

  Procedure ProcessPhrase(PhStart, PhEnd: Integer);
  Var
    i, vc, tv: Integer;
    Nuc:       Integer;
    df, lf, hat: Double;
    dist:      Integer;
    j2, voicedAhead: Integer;
  Begin
    // Count total voiced allophones in phrase (for declination denominator)
    tv := 0;
    For i := PhStart To PhEnd Do
      If AlloPhones[Indices[i]].Voiced Then Inc(tv);
    If tv = 0 Then Begin
      // All silence: fill with anchor pitch
      For i := PhStart To PhEnd Do F0Contour[i] := Params.Pitch;
      Exit;
    End;

    // Find nuclear vowel.
    // Priority 1: first level-1 or level-5 voiced non-stop (explicit primary/emphatic stress).
    // Priority 2: first level-2 voiced non-stop (secondary stress).
    // Priority 3: LAST level-3 or level-4 non-schwa voiced non-stop.
    //   English declarative sentences have default nuclear stress on the last
    //   content word.  All ordinary unstressed content vowels get stress 4 from
    //   the translator; scanning backward for the last one approximates this.
    // Priority 4: first voiced allophone (absolute fallback for silence-only phrases).
    Nuc := -1;
    For i := PhStart To PhEnd Do
      If AlloPhones[Indices[i]].Voiced And Not AlloPhones[Indices[i]].Stop Then
        If (Stresses[i] = 1) Or (Stresses[i] = 5) Then Begin Nuc := i; Break; End;
    If Nuc < 0 Then
      For i := PhStart To PhEnd Do
        If AlloPhones[Indices[i]].Voiced And Not AlloPhones[Indices[i]].Stop Then
          If Stresses[i] = 2 Then Begin Nuc := i; Break; End;
    If Nuc < 0 Then
      For i := PhEnd DownTo PhStart Do    // scan BACKWARD for last content vowel
        If AlloPhones[Indices[i]].Voiced And Not AlloPhones[Indices[i]].Stop Then
          If (Stresses[i] = 3) Or (Stresses[i] = 4) Then Begin Nuc := i; Break; End;
    If Nuc < 0 Then
      For i := PhStart To PhEnd Do
        If AlloPhones[Indices[i]].Voiced Then Begin Nuc := i; Break; End;

    // Build contour allophone by allophone
    vc := 0;
    For i := PhStart To PhEnd Do Begin
      // Declination: linear fall from TopLine to BottomLine over voiced duration
      If tv > 1 Then
        df := vc / (tv - 1)
      Else
        df := 0.5;
      lf := Params.Pitch * (TopLineMult + (BaseLineMult - TopLineMult) * df);

      // Per-allophone stress deviation from local declination line
      // (mirrors ComputePitchHz but now relative to the declination context)
      If AlloPhones[Indices[i]].Voiced And Not AlloPhones[Indices[i]].Stop Then Begin
        Case Stresses[i] Of
          5: lf := lf * 1.08;    // emphatic onset above declination
          1: lf := lf * 1.04;    // primary onset above declination (will fall via arc)
          2: lf := lf * 1.02;
          3: lf := lf * 1.00;
          4: lf := lf * 1.00;
        Else
          lf := lf * 1.28;       // schwa: high above declination
        End;
        // Boundary tone override.
        // For questions (value 4): F0Contour is set to just slightly above neutral
        // so the onset is smooth.  The actual audible rise is a cosine arc applied
        // per-sample in the synthesis loop, climbing from onset to peak over the
        // full allophone duration.  Spread allophones get a very mild lift to
        // create a gentle approach to the rising syllable.
        If BoundaryPre[i] = 4 Then Begin
          lf := lf * 1.05;   // onset: just above neutral; arc adds the rest
        End Else If BoundaryPre[i] = 2 Then Begin
          lf := lf * 1.15;   // comma: mild continuation rise
        End Else If BoundaryPre[i] = 3 Then Begin
          lf := lf * 1.30;   // period: strong terminal rise (British statement)
        End Else Begin
          // Check if we are 1 or 2 voiced allophones back from a value-4 mark
          j2 := i + 1;
          voicedAhead := 0;
          While (j2 <= PhEnd) And (voicedAhead < 3) Do Begin
            If AlloPhones[Indices[j2]].Voiced Then Begin
              Inc(voicedAhead);
              If BoundaryPre[j2] = 4 Then Begin
                Case voicedAhead Of
                  1: lf := lf * 1.03;   // one back: gentle approach
                  2: lf := lf * 1.01;   // two back: barely above neutral
                End;
                Break;
              End;
            End;
            Inc(j2);
          End;
        End;
      End;

      // Nuclear Hat overlay
      hat := 0.0;
      If (Nuc >= 0) And AlloPhones[Indices[i]].Voiced And Not AlloPhones[Indices[i]].Stop Then Begin
        dist := i - Nuc;
        // Hat arc: +HatRise at dist=-1 (pre-nuclear), tapering either side
        If Abs(dist) <= HatSpan Then Begin
          If dist < 0 Then Begin
            // Pre-nuclear rise: cosine ramp up to peak one before nucleus
            hat := Params.Pitch * HatRise *
                   Cos(Pi * 0.5 * (Abs(dist) - 1) / Max(1, HatSpan - 1));
            If hat < 0 Then hat := 0;
          End Else If dist = 0 Then Begin
            // Nuclear syllable: at declination line (the "fall" starts here)
            hat := 0.0;
          End Else Begin
            // Post-nuclear: fall below declination toward tail (British fall)
            hat := -Params.Pitch * HatRise * 0.5 *
                   Cos(Pi * 0.5 * (dist - 1) / Max(1, HatSpan));
            If hat > 0 Then hat := 0;
          End;
        End;
        lf := lf + hat;
      End;

      F0Contour[i] := Max(Params.Pitch * 0.60, Min(Params.Pitch * 2.0, lf));
      If AlloPhones[Indices[i]].Voiced Then Inc(vc);
    End;
  End;

Begin
  // Robotic mode: flat pitch throughout, both male and female
  If Params.Mode = 1 Then Begin
    For ai := 0 To AlloCount - 1 Do F0Contour[ai] := Params.Pitch;
    Exit;
  End;

  // Split utterance at phrase boundaries, process each phrase
  PhraseStart := 0;
  For ai := 0 To AlloCount - 1 Do Begin
    // Process phrase when we hit a boundary or the last allophone
    If (BoundaryPre[ai] > 0) Or (ai = AlloCount - 1) Then Begin
      ProcessPhrase(PhraseStart, ai);
      PhraseStart := ai + 1;
    End;
  End;

  // Anything remaining after last boundary
  If PhraseStart < AlloCount Then
    ProcessPhrase(PhraseStart, AlloCount - 1);
End;

// ---------------------------------------------------------------------------
// SP_NarratorSynth - main synthesis function
// ---------------------------------------------------------------------------

Function SP_NarratorSynth(Const Phonemes: aString;
                           Const Params:   TNarratorParams): TBytes;
Var
  Jitter:        Double;
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
  OnsetSamples:  Integer;
  NoiseScale:    Double;
  BurstEnv:      Double;
  AspEnv:        Double;            // aspiration envelope (voiceless stop post-burst)
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
  Stresses:       Array of Integer;  // parallel to Indices; 0=unstressed 1..5=stressed
  StressLevel:    Integer;
  StressAmpScale: Double;            // BuzzAmp multiplier
  StressPitchPeak:Double;            // Hz arc height/depth for this allophone
  StressPitchArc: Double;            // per-sample pitch offset
  EffBuzzAmp:     Double;            // stress-scaled buzz amplitude for this sample
  FallSamples:    Integer;           // samples to reach nuclear-fall trough
  CurRd:          Double;            // LF voice quality (1.0=modal, <1=pressed, >1=breathy)
  F0Contour:      Array of Double;   // pre-built utterance F0 contour, one value per allophone
  ClosureMurmur:  Double;            // buzz level during stop closure (voiced=0.12, unvoiced=0.02)
  rawNoise:       Double;
  AmpFadeLen:     Integer;
  AmpFade:        Double;
  CurBuzzAmp:     Double;
  CurNoiseAmp:    Double;
  RiseSamples:    Integer;
  AlloBoundaryPre:Array of Integer;  // 0=none 2=PA2 3=PA3 4=PA4 question
  psi:            Integer;
  BVal:           Integer;            // boundary tone value for current PA scan
  Found:          Boolean;            // used in two-pass boundary prescan
  TailLen:        Integer;
  TailFade:       Double;
  FadeOutLen:     Integer;
  VolScale:       Double;

  Function IsVowelChar(c: aChar): Boolean;
  Begin
    Result := SP_Util.Pos(c, 'AEIOU') > 0;
  End;

  // PreFortisScale
  //   Returns 0.68 (pre-fortis clipping, ~32% reduction) when a voiced non-stop
  //   allophone at position Pos is immediately followed by a voiceless stop,
  //   optionally separated by PA-pause allophones.  Returns 1.0 otherwise.
  //
  //   Pre-fortis clipping is a robust English-language effect: vowels are
  //   substantially shorter before /p t k/ (and voiceless affricates) than
  //   before /b d g/ or in open syllables.  Examples: "cat" vs "cad",
  //   "mat" vs "mad".  The Amiga does not model this; we apply it here
  //   as a "better than Amiga" enhancement.
  //
  //   The Amiga table AE stressed = 180 ms was calibrated for its FWF synthesis.
  //   In our IIR cascade, 180 ms before a stop sounds stretched.  Applying 0.68
  //   gives AE = ~122 ms in "cat" (before TT) and ~146 ms in "mat" (WFL × 1.20
  //   then × 0.68).  Both sit comfortably in the 100–160 ms range for stressed
  //   AE in British English running speech.
  //
  Function PreFortisScale(Pos: Integer): Double;
  Var
    j: Integer;
  Begin
    Result := 1.0;
    If Not AlloPhones[Indices[Pos]].Voiced Then Exit;
    If AlloPhones[Indices[Pos]].Stop      Then Exit;
    // Scan forward past any PA-pauses to find the next real allophone
    j := Pos + 1;
    While (j < AlloCount) And
          (Copy(aString(AlloPhones[Indices[j]].Name), 1, 2) = 'PA') Do
      Inc(j);
    If j >= AlloCount Then Exit;
    // Pre-fortis: next allophone is an unvoiced stop
    If (Not AlloPhones[Indices[j]].Voiced) And AlloPhones[Indices[j]].Stop Then
      Result := 0.68;
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

  // Lead-out silence — only add if the stream doesn't already end with a pause.
  // If the input ended with '?' the stream ends with PA4; adding PA2 after it
  // would cause the prescan to overwrite the PA4 boundary mark on the preceding
  // voiced allophone, silently destroying the question rise contour.
  If AlloCount > 0 Then Begin
    If (AlloPhones[Indices[AlloCount - 1]].BuzzAmp <> 0.0) Or
       (AlloPhones[Indices[AlloCount - 1]].NoiseAmp <> 0.0) Then Begin
      // Last allophone is not a pause — add trailing silence
      SetLength(Indices,  AlloCount + 1);
      SetLength(Stresses, AlloCount + 1);
      Idx := SP_NarratorFindAllophone('PA2');
      If Idx >= 0 Then Begin
        Indices[AlloCount]  := Idx;
        Stresses[AlloCount] := 0;
        Inc(AlloCount);
      End;
    End;
  End;
  SetLength(Indices,  AlloCount);
  SetLength(Stresses, AlloCount);

  // ---- Pre-scan: mark the last voiced allophone before each phrase boundary ----
  // Uses a two-pass scan: first prefer a vowel (BuzzAmp≥0.80, NoiseAmp≤0.05)
  // so boundary tones land on the perceptually prominent nucleus rather than
  // on a coda consonant.  "world?" marks ER not LL; "cat." marks AE not TT.
  // Falls back to the nearest non-stop voiced allophone if no vowel is found.
  SetLength(AlloBoundaryPre, AlloCount);
  For ai := 0 To AlloCount - 1 Do
    AlloBoundaryPre[ai] := 0;

  ai := 0;
  While ai < AlloCount Do Begin
    If (SP_Util.Upper(aString(AlloPhones[Indices[ai]].Name)) = 'PA2') Or
       (SP_Util.Upper(aString(AlloPhones[Indices[ai]].Name)) = 'PA3') Or
       (SP_Util.Upper(aString(AlloPhones[Indices[ai]].Name)) = 'PA4') Then Begin

      If SP_Util.Upper(aString(AlloPhones[Indices[ai]].Name)) = 'PA2' Then BVal := 2
      Else If SP_Util.Upper(aString(AlloPhones[Indices[ai]].Name)) = 'PA3' Then BVal := 3
      Else BVal := 4;

      // Pass 1: nearest vowel nucleus (BuzzAmp≥0.80, NoiseAmp≤0.05, voiced, not stop)
      // This ensures boundary tones land on the perceptually prominent vowel
      // nucleus rather than a coda consonant: "world?" marks ER not LL.
      Found := False;
      For psi := ai - 1 DownTo 0 Do Begin
        If AlloPhones[Indices[psi]].Voiced And
           Not AlloPhones[Indices[psi]].Stop And
           (AlloPhones[Indices[psi]].BuzzAmp >= 0.80) And
           (AlloPhones[Indices[psi]].NoiseAmp <= 0.05) Then Begin
          AlloBoundaryPre[psi] := BVal;
          Found := True;
          Break;
        End;
      End;

      // Pass 2: fallback — nearest non-stop voiced allophone
      If Not Found Then
        For psi := ai - 1 DownTo 0 Do Begin
          If AlloPhones[Indices[psi]].Voiced And Not AlloPhones[Indices[psi]].Stop Then Begin
            AlloBoundaryPre[psi] := BVal;
            Break;
          End;
        End;

    End;
    Inc(ai);
  End;

  // ---- Build utterance F0 contour ----
  // Must happen BEFORE the TotalSamples prescan.  The prescan and the main loop
  // must use the same pitch values for each allophone, otherwise the main loop
  // can write more samples than the prescan budgeted (causing a range check error
  // when WritePos walks off the end of Result).
  //
  // The discrepancy arises from phrase declination: BuildF0Contour returns
  // Params.Pitch × 0.94 for a neutral phoneme at phrase end, while the old
  // ComputePitchHz returned Params.Pitch × 1.00.  Lower pitch -> larger
  // (139/PitchHz) coupling factor -> more samples per allophone.
  RateScale := 150.0 / Max(1, Params.Rate);
  SetLength(F0Contour, AlloCount);
  BuildF0Contour(Indices, Stresses, AlloCount, Params, AlloBoundaryPre, F0Contour);

  // ---- Size ----
  TotalSamples := 0;
  For ai := 0 To AlloCount - 1 Do
    TotalSamples := TotalSamples +
      ComputeDurSamples(AlloPhones[Indices[ai]], Stresses[ai],
                        RateScale, AlloBoundaryPre[ai] > 0,
                        PreFortisScale(ai));

  BufBytes := TotalSamples * 2 + 16;
  SetLength(Result, BufBytes);
  FillChar(Result[0], BufBytes, 0);

  // ---- Init state ----
  FillChar(State, SizeOf(State), 0);
  State.NoiseSeed  := $DEADBEEF;
  State.JitterSeed := $CAFEF00D;
  CurEmph          := 0.96;

  // Prime the LF model to modal voice (Rd=1.0).
  // FillChar leaves State.LF.Ta = 0.  LFGlottalPulse evaluates Exp(0/0) = NaN
  // on the very first sample if UpdateLFParams has not been called yet, which
  // happens whenever the first allophone is unvoiced (the UpdateLFParams call
  // is guarded by "If Allo.Voiced").  NaN then propagates permanently through
  // the IIR cascade.  Calling UpdateLFParams here ensures State.LF always has
  // valid coefficients before any sample is generated.
  UpdateLFParams(State, 1.0);

  For i := 1 To 4 Do Begin
    State.PrevF[i]  := AlloPhones[Indices[0]].F[i];
    State.PrevBW[i] := AlloPhones[Indices[0]].BW[i];
    InitFormant(State.Filters[i], AlloPhones[Indices[0]].F[i], AlloPhones[Indices[0]].BW[i], SP_NARRATOR_SAMPLERATE);
    State.Filters[i].Gain := 1.0 - State.Filters[i].A1 - State.Filters[i].A2;
  End;
  InitAntiResonator(State.NasalNotch, 1150, 200, SP_NARRATOR_SAMPLERATE);

  WritePos  := 0;
  FillChar(PrevAllo, SizeOf(PrevAllo), 0);

  // ---- Main allophone loop ----
  For ai := 0 To AlloCount - 1 Do Begin
    Allo := AlloPhones[Indices[ai]];
    AlloName := SP_Util.Upper(aString(Allo.Name));

    // ---- Pause allophones: write silence and skip all synthesis ----
    // PA0..PA5, QQ and QX have F[1]=0 and BuzzAmp=0.  The old code froze
    // their formants to the previous allophone's values, meaning the IIR
    // filter delay lines still had energy in them (from e.g. OW before PA2)
    // and produced audible output during what should be silence ("pah" bug).
    // The fix: detect pause/silence allophones explicitly, zero-fill the
    // output samples, and skip ALL filter/source processing.
    // State.PrevF is NOT updated so the next voiced allophone after a pause
    // still has valid formant start-points for its transition sweep.
    If (Allo.BuzzAmp = 0.0) And (Allo.NoiseAmp = 0.0) Then Begin
      DurSamples := ComputeDurSamples(Allo, Stresses[ai],
                                      RateScale, AlloBoundaryPre[ai] > 0,
                                      PreFortisScale(ai));
      For si := 0 To DurSamples - 1 Do Begin
        If WritePos >= BufBytes - 1 Then Break;
        pSmallInt(@Result[WritePos])^ := 0;
        Inc(WritePos, 2);
      End;
      // Do NOT set PrevAllo or State.PrevF — preserve them for the next allophone
      Continue;
    End;

    // For mid-word glottal stops and silent allophones that DO have formants,
    // freeze the mouth in its previous shape so the vocal tract doesn't collapse.
    If (Allo.F[1] = 0) And (ai > 0) Then Begin
      For i := 1 To 4 Do Begin
        Allo.F[i]  := Round(State.PrevF[i]);
        Allo.BW[i] := Round(State.PrevBW[i]);
      End;
    End;

    StressLevel := Stresses[ai];

    // ---- Stress-driven amplitude and pitch-arc parameters ----
    // Duration is now handled entirely by ComputeDurSamples (two-table +
    // pitch coupling).  Only amplitude and pitch arc are set here.
    //
    // Pitch arc design (matching Amiga FUN_002211b8):
    //   ComputePitchHz returns the ONSET pitch (slightly above neutral for
    //   stressed syllables, so the arc can fall into the nuclear trough).
    //   StressPitchPeak < 0 -> falling arc (nuclear fall for levels 1, 2, 5).
    //   StressPitchPeak > 0 -> rising arc (tertiary/schwa).
    //   StressPitchPeak = 0 -> flat (neutral, level 4).
    If Allo.Voiced And Not Allo.Stop Then Begin
      Case StressLevel Of
        5: Begin  // emphatic — strong nuclear fall
             StressAmpScale  := 1.20;
             StressPitchPeak := -(Params.Pitch * 0.18);  // onset 1.08× -> trough 0.90×
           End;
        1: Begin  // primary stress — nuclear fall (Amiga: ~134/139 = 0.964 at trough)
             StressAmpScale  := 1.12;
             StressPitchPeak := -(Params.Pitch * 0.075); // onset 1.04× -> trough 0.965×
           End;
        2: Begin  // secondary stress — modest fall
             StressAmpScale  := 1.08;
             StressPitchPeak := -(Params.Pitch * 0.040); // onset 1.02× -> trough 0.980×
           End;
        3: Begin  // tertiary — slight rise
             StressAmpScale  := 1.03;
             StressPitchPeak := +(Params.Pitch * 0.030);
           End;
        4: Begin  // neutral — flat at anchor (Amiga: no pitch write, stays at default)
             StressAmpScale  := 1.00;
             StressPitchPeak := 0.0;
           End;
      Else Begin  // 0 = schwa — high and flat (Amiga ~178 Hz ceiling)
             StressAmpScale  := 0.72;
             StressPitchPeak := 0.0;
           End;
      End;
    End Else Begin
      StressAmpScale  := 1.00;
      StressPitchPeak := 0.0;
    End;

    // ---- LF voice quality (Rd) ----
    // Stressed syllables -> slightly more pressed (brighter, more percussive).
    // Schwa / unstressed -> slightly breathier (softer, more natural).
    // Female voice is inherently breathier than male.
    If Params.Sex = 1 Then
      CurRd := 1.60           // female: breathy
    Else
      Case StressLevel Of
        5: CurRd := 0.75;     // emphatic — noticeably pressed
        1: CurRd := 0.85;     // primary stress — slightly pressed
        2: CurRd := 0.95;     // secondary — near modal
        3: CurRd := 1.05;     // tertiary — slightly open
        4: CurRd := 1.10;     // neutral — modal/open
      Else
        CurRd := 1.40;        // schwa — relaxed, breathy
      End;

    // Update LF model coefficients once per allophone (not per sample)
    If Allo.Voiced Then UpdateLFParams(State, CurRd);

    BypassF1 := (Allo.Stop) Or ((Allo.NoiseAmp >= 0.10) And (AlloName <> 'HH'));

    If (Allo.Stop And Not PrevAllo.Nasal) Or
       (Not Allo.Nasal And PrevAllo.Nasal) Then Begin
      State.NasalNotch.X1 := 0;
      State.NasalNotch.X2 := 0;
    End;

    // Scale duration by pitch ratio to match the Amiga's pitch-coupled duration model.
    // The Amiga measures phoneme duration in glottal cycles (waveform-table passes).
    // At the Amiga's internal base pitch of 139 Hz, the decoded Amiga duration table
    // values (our DurMs) produce the correct millisecond durations. At lower pitch,
    // each glottal cycle is longer, so phonemes take proportionally more time.
    // Duration from Amiga two-table system (stressed/unstressed), with WFL and
    // pre-fortis clipping applied.  Pitch has no effect on timing.
    DurSamples := ComputeDurSamples(Allo, StressLevel,
                                    RateScale, AlloBoundaryPre[ai] > 0,
                                    PreFortisScale(ai));

    // Diphthongs must be calculated before PrevAllo.Stop so their glides aren't truncated!
    IsDiphthong := (AlloName = 'AY') Or (AlloName = 'AW') Or (AlloName = 'OY') Or
                   (AlloName = 'EY') Or (AlloName = 'OW');

    If Allo.Stop Then
      TransSamples := Max(1, DurSamples Div 5)
    Else If IsDiphthong Then
      TransSamples := Max(1, (DurSamples * 4) Div 5)
    Else If PrevAllo.Stop Or (PrevAllo.Nasal And Not Allo.Nasal) Then
      // After a stop or nasal, onset formants snap quickly to target.
      // Nasals have very different formant structure from oral vowels;
      // a slow sweep audibly passes through back-vowel territory ("moo" effect).
      TransSamples := Max(1, DurSamples Div 4)
    Else If (Allo.DurMs >= 130) And Allo.Voiced And Not Allo.Nasal And Not Allo.Stop Then
      TransSamples := Max(1, (DurSamples * 4) Div 5)
    Else If Allo.NoiseAmp > Allo.BuzzAmp Then
      TransSamples := Max(1, DurSamples Div 4)
    Else
      TransSamples := Max(1, DurSamples * 2 Div 5);

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
    If (PrevAllo.DurMs = 0) Or (PrevAllo.F[1] = 0) Or (PrevAllo.Name = 'HH') Then Begin
      For i := 1 To 4 Do Begin
        SavePrevF[i]  := Allo.F[i];
        SavePrevBW[i] := Allo.BW[i];
      End;
    End;

    IsDiphthong := (AlloName = 'AY') Or (AlloName = 'AW') Or (AlloName = 'OY') Or
                   (AlloName = 'EY') Or (AlloName = 'OW');
    // Always force the correct phonetic onset for diphthongs.
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

    // ---- Pitch Hz for this allophone ----
    // Read from the pre-built utterance F0 contour.  BuildF0Contour has already
    // incorporated phrase declination, the nuclear Hat pattern, and boundary
    // tones for every allophone.  The per-sample StressPitchArc (computed below
    // in the inner loop) then adds the intra-allophone rise or fall arc on top.
    PitchHz := F0Contour[ai];

    NextCoeffAt := 0;

    // ---- Per-sample loop ----
    For si := 0 To DurSamples - 1 Do Begin
      If WritePos >= BufBytes - 1 Then Break;

      If si >= NextCoeffAt Then Begin
        If TransSamples > 0 Then Progress := Min(1.0, si / TransSamples) Else Progress := 1.0;
        UpdateFormantCoeffs(State, Allo, Params, Progress, SavePrevF, SavePrevBW, StressLevel);
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
      // Models the Amiga's per-slot pitch contour (FUN_00220a8e / FUN_002211b8).
      //
      // Special case: question boundary (AlloBoundaryPre=4).
      // The F0Contour onset is set to just above neutral (~1.05×); the arc here
      // adds a smooth cosine S-curve rise from 0 to +QuestionArcPeak over the
      // full allophone duration.  This produces a clearly audible, smooth rise
      // rather than a step-function jump.  QuestionArcPeak = 22% of Params.Pitch:
      // at 120 Hz that's a 0->26 Hz rise, landing ~152 Hz at the end.
      If (AlloBoundaryPre[ai] = 4) And Allo.Voiced And (DurSamples > 0) Then Begin
        StressPitchArc := (Params.Pitch * 0.22) *
          (1.0 - Cos(Pi * si / DurSamples)) * 0.5;
      End Else If Allo.Voiced And (DurSamples > 0) And (StressPitchPeak <> 0.0) Then Begin
        If StressPitchPeak < 0 Then Begin
          // Nuclear fall: fast descent, hold at trough
          FallSamples := Max(1, DurSamples Div 3);
          If si < FallSamples Then
            StressPitchArc := StressPitchPeak * (si / FallSamples)
          Else
            StressPitchArc := StressPitchPeak;   // hold trough for rest of phoneme
        End Else Begin
          // Rise (tertiary): fast ascent to peak, slow cosine decay
          RiseSamples := Max(1, DurSamples Div 5);
          If si < RiseSamples Then
            StressPitchArc := StressPitchPeak * (si / RiseSamples)
          Else
            StressPitchArc := StressPitchPeak *
              Cos((Pi / 2.0) * ((si - RiseSamples) /
               Max(1.0, (DurSamples - RiseSamples))));
        End;
      End Else
        StressPitchArc := 0.0;

      // ---- Pitch jitter ----
      // Cycle-to-cycle F0 microvariation (~0.4% peak). Uses a separate seed
      // so it does not correlate with the fricative noise source.
      // A slow random walk (5 Hz bandwidth) replicates biological glottal irregularity.
      If Allo.Voiced Then Begin
        State.JitterSeed := LongWord(UInt64(State.JitterSeed) * 1664525 + 1013904223);
        Jitter := (Integer(State.JitterSeed) / 2147483648.0) * (PitchHz * 0.003);
      End Else
        Jitter := 0.0;

      // ---- Source ----
      // Stress amplitude: scale buzz source; clamp so we never exceed unity
      EffBuzzAmp := Allo.BuzzAmp * StressAmpScale;
      If EffBuzzAmp > 1.0 Then EffBuzzAmp := 1.0;

      If Allo.Stop Then Begin

        // Pre-voicing murmur level during closure.
        // Voiced stops /b d g/ have audible low-level buzz leaking through the
        // oral closure because the vocal folds keep vibrating.  This murmur is
        // the primary acoustic cue that distinguishes voiced from voiceless stops.
        // Without it, the closure is pure silence -> the subsequent voicing ramp
        // sounds like a glide (BB = "w"-like onset rather than "b").
        // 12% for voiced, 2% for voiceless (near-silence for /p t k/).
        If Allo.Voiced Then ClosureMurmur := 0.12 Else ClosureMurmur := 0.02;

        If si < StopSamples Then Begin
          // Closure phase: fade from previous allophone's buzz down to murmur level
          FadeLen := Min(441, StopSamples);
          If (si < FadeLen) And (FadeLen > 0) Then Begin
            ClosureFade := 1.0 - (si / FadeLen);
            PrevBuzz := PrevAllo.BuzzAmp;
            If PrevAllo.Stop Then PrevBuzz := PrevAllo.BuzzAmp * ClosureMurmur;

            BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) *
                        (PrevBuzz * ClosureFade + EffBuzzAmp * ClosureMurmur * (1.0 - ClosureFade));
          End Else Begin
            BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp * ClosureMurmur;
          End;
        End Else Begin
          // Release phase
          BurstTime := si - StopSamples;

          // Voicing onset ramp: voiced stops ramp up quickly (5ms) from the
          // murmur level — a short VOT matching natural /b d g/.
          // Voiceless stops use 15ms starting from near-silence.
          If Allo.Voiced Then Begin
            If BurstTime < 220 Then  // 5ms ramp
              BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp * (ClosureMurmur + (1.0 - ClosureMurmur) * (BurstTime / 220.0))
            Else
              BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp;
          End Else Begin
            If BurstTime < 660 Then  // 15ms ramp for voiceless
              BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp * (0.02 + 0.98 * (BurstTime / 660.0))
            Else
              BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) * EffBuzzAmp;
          End;

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
            // Affricates sustain friction throughout their release phase.
            // When the next allophone is voiced (e.g. CH->UN in "question"),
            // fade out the friction over the last 20ms to reduce forward masking.
            // Without this fade, the abrupt full-amplitude cutoff leaves the
            // auditory masking window active when the following nasal/vowel starts,
            // making the subsequent sound appear very short regardless of duration.
            If AlloPhones[Indices[Min(ai + 1, AlloCount - 1)]].Voiced Then Begin
              TailLen := Min(882, DurSamples - StopSamples);  // ~20ms
              If (DurSamples - si) < TailLen Then
                TailFade := (DurSamples - si) / TailLen
              Else
                TailFade := 1.0;
              FricPart := RawNoise * NoiseAttack * TailFade;
            End Else
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
            End Else If Not Allo.Voiced Then Begin
              // Aspiration: 20ms of pink-noise breath after the burst, for
              // voiceless stops only (PP TT KK).  Pink noise is already
              // low-pass filtered (PinkNoiseX1) so it adds no click or transient.
              // Cosine fade-out from the burst's end to silence.
              // This is the acoustic VOT region — the breathy period that
              // distinguishes "pin" from "bin" in English.
              // AspirationLen = 882 ≈ 20ms at 44100 Hz
              If (BurstTime - PlosiveLen) < 882 Then Begin
                AspEnv := 0.5 * (1.0 + Cos(Pi * (BurstTime - PlosiveLen) / 882.0));
                FricPart := State.PinkNoiseX1 * Allo.NoiseAmp * 0.22 * AspEnv;
              End Else
                FricPart := 0;
            End Else
              FricPart := 0;
          End;

        End;
      End Else Begin
        // Amplitude crossfade: blend BuzzAmp and NoiseAmp from the previous
        // allophone's values to this allophone's values over ~8 ms (353 samples).
        // Prevents pops at voiced<->unvoiced boundaries and fricative onsets.
        // Standard crossfade ~12ms, extended to ~25ms at fricative->fricative
        // voicing boundaries (e.g. SS->ZZ, SH->ZH, FF->VV, TH->DH) where
        // both allophones are sustained and the voicing transition is abrupt.
        // Stops are excluded from the 25ms path: their release is already
        // handled by the burst code above, so the following voiced allophone
        // (e.g. CH->UN in "question") should onset in 12ms, not 25ms.
        If (PrevAllo.NoiseAmp > PrevAllo.BuzzAmp) And
           (Not PrevAllo.Stop) And
           (Allo.NoiseAmp > 0) And
           (Allo.Voiced <> PrevAllo.Voiced) Then
          AmpFadeLen := Min(1102, DurSamples Div 2)  // ~25ms
        Else
          AmpFadeLen := Min(529, DurSamples Div 2);  // ~12ms
        If (si < AmpFadeLen) And (AmpFadeLen > 0) Then
          AmpFade := si / AmpFadeLen
        Else
          AmpFade := 1.0;
        CurBuzzAmp  := PrevAllo.BuzzAmp  + (EffBuzzAmp    - PrevAllo.BuzzAmp)  * AmpFade;
        CurNoiseAmp := PrevAllo.NoiseAmp + (Allo.NoiseAmp - PrevAllo.NoiseAmp) * AmpFade;

        BuzzPart := LFGlottalPulse(State.BuzzPhase, State.LF, PitchHz + StressPitchArc + Jitter, SP_NARRATOR_SAMPLERATE) * CurBuzzAmp;

        If AlloName = 'HH' Then Begin
          OnsetSamples := Round(0.025 * SP_NARRATOR_SAMPLERATE);
          If si < OnsetSamples Then NoiseScale := si / OnsetSamples Else NoiseScale := 1.0;
        End Else NoiseScale := 1.0;

        // Fade out noise at the end of unvoiced fricatives when the next
        // allophone is voiced — prevents the abrupt noise cutoff click
        // at SS->vowel, FF->vowel, TH->DH boundaries.
        If (Not Allo.Voiced) And (Not Allo.Stop) And
           (Allo.NoiseAmp > 0.5) And
           AlloPhones[Indices[Min(ai + 1, AlloCount - 1)]].Voiced Then Begin
          TailLen := Min(882, DurSamples Div 3);  // ~20ms tail
          If (DurSamples - si) < TailLen Then
            TailFade := (DurSamples - si) / TailLen
          Else
            TailFade := 1.0;
          If BypassF1 Then
            FricPart := State.PinkNoiseX1 * CurNoiseAmp * NoiseScale * TailFade
          Else
            AspPart := State.PinkNoiseX1 * CurNoiseAmp * NoiseScale * TailFade;
        End Else Begin
          If BypassF1 Then
            FricPart := State.PinkNoiseX1 * CurNoiseAmp * NoiseScale
          Else
            AspPart := State.PinkNoiseX1 * CurNoiseAmp * NoiseScale;
        End;

      End;

      if (ai = AlloCount - 1) or
         ((AlloPhones[Indices[ai+1]].BuzzAmp = 0) and (AlloPhones[Indices[ai+1]].NoiseAmp = 0)) then
      begin
        // Fade out over the last 40ms (approx 1764 samples at 44.1kHz)
        FadeOutLen := Min(1764, DurSamples div 2);
        if (DurSamples - si) < FadeOutLen then begin
          VolScale := (DurSamples - si) / FadeOutLen;
          // Apply a cosine curve for a more organic "tail off"
          VolScale := 0.5 * (1.0 - Cos(Pi * VolScale));

          BuzzPart := BuzzPart * VolScale;
          FricPart := FricPart * VolScale;
          AspPart  := AspPart * VolScale;
        end;
      end;

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
  If Channel = 0 Then Begin
    BASS_SampleFree(Sample);
    Exit;
  End;
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
