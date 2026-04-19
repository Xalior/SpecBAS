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

unit SP_NarratorTranslator;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses SP_Util, SysUtils;

Function SP_IsAmigaSpeech(Const s: aString): Boolean;
Function SP_NarratorTranslate(Const Text: aString): aString;
Function SP_NarratorFromAmiga(Const AmigaStr: aString): aString;

implementation

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

Const

  Vowels     = 'AEIOU';
  FrontVowels = 'EIY';
  Consonants = 'BCDFGHJKLMNPQRSTVWXYZ';

  // Abbreviation table - expanded before LTS rules run
  AbbrevCount = 20;
  Abbrevs: Array[0..AbbrevCount-1, 0..1] of aString = (
    ('MR',   'MISTER'),
    ('MRS',  'MISSUS'),
    ('MS',   'MIZ'),
    ('DR',   'DOCTOR'),
    ('ST',   'STREET'),
    ('AVE',  'AVENUE'),
    ('BLVD', 'BOULEVARD'),
    ('APT',  'APARTMENT'),
    ('DEPT', 'DEPARTMENT'),
    ('EST',  'ESTABLISHED'),
    ('ETC',  'ETCETERA'),
    ('GOVT', 'GOVERNMENT'),
    ('LTD',  'LIMITED'),
    ('MAX',  'MAXIMUM'),
    ('MIN',  'MINIMUM'),
    ('OZ',   'OUNCES'),
    ('LB',   'POUNDS'),
    ('FT',   'FEET'),
    ('YD',   'YARDS'),
    ('MI',   'MILES')
  );

  // Period-required abbreviations -- only expanded when immediately followed
  // by '.' in the original text (e.g. "No. 5", "6 in.").
  // These words are also common English words so must not expand unconditionally.
  PeriodAbbrevCount = 2;
  PeriodAbbrevs: Array[0..PeriodAbbrevCount-1, 0..1] of aString = (
    ('NO', 'NUMBER'),
    ('IN', 'INCHES')
  );

  // Single digit words
  Ones: Array[0..19] of aString = (
    'ZERO', 'ONE', 'TWO', 'THREE', 'FOUR', 'FIVE', 'SIX', 'SEVEN',
    'EIGHT', 'NINE', 'TEN', 'ELEVEN', 'TWELVE', 'THIRTEEN', 'FOURTEEN',
    'FIFTEEN', 'SIXTEEN', 'SEVENTEEN', 'EIGHTEEN', 'NINETEEN'
  );

  Tens: Array[2..9] of aString = (
    'TWENTY', 'THIRTY', 'FORTY', 'FIFTY',
    'SIXTY', 'SEVENTY', 'EIGHTY', 'NINETY'
  );

// ---------------------------------------------------------------------------
// Number to words
// ---------------------------------------------------------------------------

Function NumberToWords(n: Integer): aString; Forward;

Function NumberToWords(n: Integer): aString;
Begin
  Result := '';

  If n < 0 Then Begin
    Result := 'MINUS ' + NumberToWords(-n);
    Exit;
  End;

  If n = 0 Then Begin
    Result := 'ZERO';
    Exit;
  End;

  If n >= 1000000 Then Begin
    Result := NumberToWords(n Div 1000000) + ' MILLION';
    n := n Mod 1000000;
    If n > 0 Then Result := Result + ' ';
  End;

  If n >= 1000 Then Begin
    Result := Result + NumberToWords(n Div 1000) + ' THOUSAND';
    n := n Mod 1000;
    If n > 0 Then Result := Result + ' ';
  End;

  If n >= 100 Then Begin
    Result := Result + Ones[n Div 100] + ' HUNDRED';
    n := n Mod 100;
    If n > 0 Then Result := Result + ' ';
  End;

  If n >= 20 Then Begin
    Result := Result + Tens[n Div 10];
    n := n Mod 10;
    If n > 0 Then Result := Result + ' ' + Ones[n];
  End Else
    If n > 0 Then
      Result := Result + Ones[n];
End;

// ---------------------------------------------------------------------------
// Text normalisation
// ---------------------------------------------------------------------------

// Returns True if c is alphabetic
Function IsAlpha(c: aChar): Boolean;
Begin
  Result := (c >= 'A') And (c <= 'Z');
End;

// Returns True if c is a digit
Function IsDigit(c: aChar): Boolean;
Begin
  Result := (c >= '0') And (c <= '9');
End;

// Expand abbreviations - whole-word matches only
Function ExpandAbbreviations(Const s: aString): aString;
Var
  i, j, wStart, wEnd: Integer;
  Word, Expanded: aString;
  Found: Boolean;
Begin
  Result := '';
  i := 1;
  While i <= Length(s) Do Begin
    // Find start of word
    If IsAlpha(s[i]) Then Begin
      wStart := i;
      While (i <= Length(s)) And IsAlpha(s[i]) Do Inc(i);
      wEnd := i - 1;
      Word := Copy(s, wStart, wEnd - wStart + 1);

      // Check abbreviation table
      Found := False;
      For j := 0 To AbbrevCount - 1 Do
        If Word = Abbrevs[j][0] Then Begin
          Expanded := Abbrevs[j][1];
          Found := True;
          Break;
        End;

      If Found Then
        Result := Result + Expanded
      Else
        Result := Result + Word;
    End Else Begin
      Result := Result + s[i];
      Inc(i);
    End;
  End;
End;

// Expand period-required abbreviations.
// Called on the UPPERCASED original text, before punctuation is stripped.
// Only expands WORD. patterns -- the period is consumed (it was a
// disambiguation marker, not a sentence-ending pause).
Function ExpandPeriodAbbreviations(Const s: aString): aString;
Var
  i, j, wStart, wEnd: Integer;
  Word, Expanded: aString;
  Found: Boolean;
Begin
  Result := '';
  i := 1;
  While i <= Length(s) Do Begin
    If IsAlpha(s[i]) Then Begin
      wStart := i;
      While (i <= Length(s)) And IsAlpha(s[i]) Do Inc(i);
      wEnd := i - 1;
      Word := Copy(s, wStart, wEnd - wStart + 1);
      // Only expand if the word is immediately followed by '.'
      If (i <= Length(s)) And (s[i] = '.') Then Begin
        Found := False;
        For j := 0 To PeriodAbbrevCount - 1 Do
          If Word = PeriodAbbrevs[j][0] Then Begin
            Expanded := PeriodAbbrevs[j][1];
            Found := True;
            Break;
          End;
        If Found Then Begin
          Result := Result + Expanded;
          Inc(i); // consume the period -- it was just a disambiguation marker
          Continue;
        End;
      End;
      Result := Result + Word;
    End Else Begin
      Result := Result + s[i];
      Inc(i);
    End;
  End;
End;

// Expand a run of digits starting at position i in s.
// Advances i past the digits consumed.
Function ExpandDigits(Const s: aString; Var i: Integer): aString;
Var
  NumStr: aString;
  n: Integer;
Begin
  NumStr := '';
  While (i <= Length(s)) And IsDigit(s[i]) Do Begin
    NumStr := NumStr + s[i];
    Inc(i);
  End;
  n := StrToIntDef(String(NumStr), 0);
  Result := NumberToWords(n);
End;

// Main normalisation:
//   - Uppercase
//   - Expand digits
//   - Expand abbreviations
//   - Convert punctuation to pause markers
//   - Strip anything else non-alpha
Function NormaliseText(Const Text: aString): aString;
Var
  s: aString;
  i: Integer;
  c: aChar;
Begin
  s := SP_Util.Upper(Text);
  s := ExpandPeriodAbbreviations(s); // Expand NO./IN. etc. before punctuation is stripped
  Result := '';
  i := 1;

  While i <= Length(s) Do Begin
    c := s[i];
    If IsDigit(c) Then Begin
      // Single digits pass through to LTS rules which handle them
      // with proper stress marks. Multi-digit numbers expand to words.
      If (i + 1 <= Length(s)) And Not IsDigit(s[i + 1]) Then Begin
        // Single digit - check for ordinal suffix first
        If (Result <> '') And (Result[Length(Result)] <> ' ') Then
          Result := Result + ' ';
        Result := Result + c;
        Inc(i);
        // Absorb ordinal suffix if present (ST ND RD TH)
        If (i + 1 <= Length(s)) Then Begin
          If (s[i] = 'S') And (s[i+1] = 'T') Then Begin
            Result := Result + 'ST'; Inc(i, 2);
          End Else If (s[i] = 'N') And (s[i+1] = 'D') Then Begin
            Result := Result + 'ND'; Inc(i, 2);
          End Else If (s[i] = 'R') And (s[i+1] = 'D') Then Begin
            Result := Result + 'RD'; Inc(i, 2);
          End Else If (s[i] = 'T') And (s[i+1] = 'H') Then Begin
            Result := Result + 'TH'; Inc(i, 2);
          End;
        End;
        Result := Result + ' ';
      End Else Begin
        // Multi-digit number - expand to words as before
        If (Result <> '') And (Result[Length(Result)] <> ' ') Then
          Result := Result + ' ';
        Result := Result + ExpandDigits(s, i);
        Result := Result + ' ';
      End;
    End Else If IsAlpha(c) Then Begin
      Result := Result + c;
      Inc(i);
    End Else Begin
      Case c Of
        '.', '!', ';': Begin
          Result := Result + ' . ';  // sentence boundary - long pause
          Inc(i);
        End;
        ',': Begin
          Result := Result + ' , ';  // clause boundary - short pause
          Inc(i);
        End;
        '?': Begin
          Result := Result + ' ? ';  // question - long pause
          Inc(i);
        End;
        '-': Begin
          Result := Result + ' ';    // hyphen - word boundary
          Inc(i);
        End;
        '''': Begin
          Result := Result + '''';   // preserve apostrophe for contractions
          Inc(i);
        End;
        ' ', #9, #13, #10: Begin
          Result := Result + ' ';
          Inc(i);
        End;
      Else
        Inc(i);                      // skip unknown characters
      End;
    End;
  End;

  // Expand abbreviations on the resulting uppercase word stream
  Result := ExpandAbbreviations(Result);

  // Collapse multiple spaces
  While SP_Util.Pos('  ', Result) > 0 Do
    Result := aString(StringReplace(String(Result), '  ', ' ', [rfReplaceAll]));

  Result := aString(SP_Trim(Result));
End;

// ---------------------------------------------------------------------------
// LTS Rule types and table
// ---------------------------------------------------------------------------

Type
  TLTSRule = Record
    LeftCtx:  aString;
    Letters:  aString;
    RightCtx: aString;
    Phonemes: aString;
  End;

Const

// Context symbols:
//   #  = one or more vowels (AEIOU)
//   :  = zero or more consonants
//   ^  = exactly one consonant
//   +  = front vowel (E I Y)
//   @  = suffix consonant (D G J L N R S T Z)
//   %  = suffix (ER ED ING E EST)
//   ' '= word boundary (space or start/end)
//
// Rules tried top to bottom; first match wins.
// Empty LeftCtx/RightCtx matches anything.

LTSRuleCount = 727;

  LTSRules: Array[0..LTSRuleCount-1] of TLTSRule = (

    // -------------------------------------------------------
    // A
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'A';    RightCtx:'. ';  Phonemes:'EH3 YY'),        // letter name
    (LeftCtx:' '; Letters:'A';    RightCtx:' ';   Phonemes:'AH'),            // standalone A
    (LeftCtx:' '; Letters:'A';    RightCtx:' ';   Phonemes:'AH'),
    (LeftCtx:'';  Letters:'A';    RightCtx:' ';   Phonemes:'AH'),
    (LeftCtx:' '; Letters:'ARE';  RightCtx:' ';   Phonemes:'AA RR'),
    (LeftCtx:' '; Letters:'AND';  RightCtx:' ';   Phonemes:'AE NN DD'),
    (LeftCtx:' '; Letters:'AS';   RightCtx:' ';   Phonemes:'AE ZZ'),
    (LeftCtx:' '; Letters:'AT';   RightCtx:' ';   Phonemes:'AE TT'),
    (LeftCtx:' '; Letters:'AN';   RightCtx:' ';   Phonemes:'AE NN'),
    (LeftCtx:' '; Letters:'AM';   RightCtx:' ';   Phonemes:'AE MM'),
    (LeftCtx:' '; Letters:'AREN''T'; RightCtx:''; Phonemes:'AA1 RR IH NN TT'),
    (LeftCtx:' '; Letters:'ABOVE';RightCtx:'';    Phonemes:'AH BB AH3 VV'),
    (LeftCtx:' '; Letters:'AROUND';RightCtx:'';   Phonemes:'AH RR AW3 NN DD'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'DAP';  Phonemes:'AX'),
    (LeftCtx:' '; Letters:'AVE.'; RightCtx:' ';   Phonemes:'AE2 VV IH NN UW'),
    (LeftCtx:'';  Letters:'AR';   RightCtx:'O';    Phonemes:'AX RR'),
    (LeftCtx:'';  Letters:'AR';   RightCtx:'#';    Phonemes:'EH RR'),
    (LeftCtx:'^'; Letters:'AS';   RightCtx:'#';    Phonemes:'EY SS'),
    (LeftCtx:'';  Letters:'AW';   RightCtx:'';     Phonemes:'AO'),
    (LeftCtx:'';  Letters:'AI';   RightCtx:'';     Phonemes:'EY'),
    (LeftCtx:'';  Letters:'AY';   RightCtx:'';     Phonemes:'EY'),
    (LeftCtx:'';  Letters:'AU';   RightCtx:'';     Phonemes:'AO3'),
    (LeftCtx:'';  Letters:'ALL';  RightCtx:' ';    Phonemes:'AO LL'),
    (LeftCtx:'';  Letters:'ALK';  RightCtx:'';     Phonemes:'AO3 KK'),
    (LeftCtx:' '; Letters:'ABLE'; RightCtx:'';     Phonemes:'EY3 BB UL'),
    (LeftCtx:' '; Letters:'A';    RightCtx:'BOU';  Phonemes:'AX'),
    (LeftCtx:' '; Letters:'A';    RightCtx:'BOV';  Phonemes:'AX'),
    (LeftCtx:'';  Letters:'APE';  RightCtx:'';     Phonemes:'EY PP'),
    (LeftCtx:'';  Letters:'AGAIN';RightCtx:'';     Phonemes:'AX GG EH3 NN'),
    (LeftCtx:' '; Letters:'AGO';  RightCtx:' ';    Phonemes:'AH GG OW2'),
    (LeftCtx:' '; Letters:'ANOTHER'; RightCtx:'';  Phonemes:'AH NN AH3 DH ER'),
    (LeftCtx:'';  Letters:'ABOUT';RightCtx:'';     Phonemes:'AX BB AW1 TT'),
    (LeftCtx:' '; Letters:'APPLE';RightCtx:'';     Phonemes:'AE3 PP UL'),
    (LeftCtx:' '; Letters:'AMIGA';RightCtx:'';     Phonemes:'AH MM IY3 GG AH'),
    (LeftCtx:' '; Letters:'ATARI';RightCtx:'';     Phonemes:'AH TT AA3 RR IY'),
    (LeftCtx:' '; Letters:'ATOMIC';RightCtx:'';    Phonemes:'AH TT AA3 MM IH KK'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'TOM';  Phonemes:'AE2'),
    (LeftCtx:'#'; Letters:'AG';   RightCtx:'E';    Phonemes:'IH JH'),
    // A before -TION/-SION: nation→EY, station→EY, occasion→EY, invasion→EY.
    // Without this rule, A falls through to AE (default), giving "nah-shun".
    // E/I/O/U before TION are handled by their own sections; A was the only gap.
    (LeftCtx:'';  Letters:'A';    RightCtx:'TION'; Phonemes:'EY3'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'SION'; Phonemes:'EY3'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'^%';   Phonemes:'EY'),
    (LeftCtx:'';  Letters:'AL';   RightCtx:'F ';   Phonemes:'AE2'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'^+:#'; Phonemes:'AE'),
    (LeftCtx:' '; Letters:'A';    RightCtx:'^+ ';  Phonemes:'EY3'),
    (LeftCtx:' '; Letters:'ARR';  RightCtx:'';     Phonemes:'AX RR'),
    (LeftCtx:'';  Letters:'ARR';  RightCtx:'';     Phonemes:'AE RR'),
    (LeftCtx:' '; Letters:'AR';   RightCtx:' ';    Phonemes:'AA3 RR'),
    (LeftCtx:'';  Letters:'AR';   RightCtx:' ';    Phonemes:'ER'),
    (LeftCtx:'';  Letters:'AR';   RightCtx:'';     Phonemes:'AA RR'),
    (LeftCtx:'';  Letters:'AIR';  RightCtx:'';     Phonemes:'EH4 RR'),
    (LeftCtx:'';  Letters:'AI';   RightCtx:'';     Phonemes:'EY3'),
    (LeftCtx:'';  Letters:'AY';   RightCtx:'';     Phonemes:'EY3'),
    (LeftCtx:'';  Letters:'AU';   RightCtx:'';     Phonemes:'AO3'),
    (LeftCtx:'#'; Letters:'AL';   RightCtx:' ';    Phonemes:'UL'),
    (LeftCtx:'#'; Letters:'ALS';  RightCtx:' ';    Phonemes:'UL ZZ'),
    (LeftCtx:'';  Letters:'ALK';  RightCtx:'';     Phonemes:'AO3 KK'),
    (LeftCtx:'';  Letters:'AL';   RightCtx:'^';    Phonemes:'AOL'),
    (LeftCtx:' '; Letters:'ABLE'; RightCtx:'';     Phonemes:'EY3 BB UL'),
    (LeftCtx:'';  Letters:'ABLE'; RightCtx:'';     Phonemes:'AX BB UL'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'VO';   Phonemes:'EY3'),
    (LeftCtx:'';  Letters:'ANG';  RightCtx:'+';    Phonemes:'EY3 NJ'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'TTI';  Phonemes:'AE'),
    (LeftCtx:' '; Letters:'A';    RightCtx:'T';    Phonemes:'AX'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'A';    Phonemes:''),
    // Syllabic L: VCal word-final → UL.  pedal, metal, total, vocal, final, rival.
    // Left context '#:^' = vowel + any consonants + one consonant immediately before AL.
    // Complements the existing L + '%' rule which handles -LE (bottle, little).
    (LeftCtx:'#:^'; Letters:'AL'; RightCtx:' ';   Phonemes:'UL'),
    (LeftCtx:'';  Letters:'A';    RightCtx:'';     Phonemes:'AE'),

    // -------------------------------------------------------
    // B
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'B';    RightCtx:'. ';   Phonemes:'BIY4'),
    (LeftCtx:' '; Letters:'BE';   RightCtx:' ';    Phonemes:'BB IY'),
    (LeftCtx:' '; Letters:'BECAUSE'; RightCtx:'';  Phonemes:'BB IH KK AH1 ZZ'),
    (LeftCtx:' '; Letters:'BE';   RightCtx:'^#';   Phonemes:'BB IX'),
    (LeftCtx:'';  Letters:'BEING';RightCtx:'';     Phonemes:'BB IY2 IH NX'),
    (LeftCtx:' '; Letters:'BOTH'; RightCtx:' ';    Phonemes:'BB OW3 TH'),
    (LeftCtx:' '; Letters:'BY';   RightCtx:' ';    Phonemes:'BB AY'),
    (LeftCtx:' '; Letters:'BUT';  RightCtx:' ';    Phonemes:'BB AH TT'),
    (LeftCtx:' '; Letters:'BEEN'; RightCtx:' ';    Phonemes:'BB IH NN'),
    (LeftCtx:' '; Letters:'BUS';  RightCtx:'#';    Phonemes:'BB IH3 ZZ'),
    (LeftCtx:'';  Letters:'BREAK';RightCtx:'';     Phonemes:'BB RR EY3 KK'),
    (LeftCtx:'';  Letters:'BEFORE';RightCtx:'';    Phonemes:'BB IX FF OH2 RR'),
    (LeftCtx:'';  Letters:'BUIL'; RightCtx:'';     Phonemes:'BB IH3 LL'),
    (LeftCtx:'';  Letters:'BELOW';RightCtx:'';     Phonemes:'BB IH LL OW2'),
    (LeftCtx:'';  Letters:'BETWEEN';RightCtx:'';   Phonemes:'BB IX TT WW IY2 NN'),
    (LeftCtx:'B';Letters:'B';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'B';    RightCtx:'';     Phonemes:'BB'),

    // -------------------------------------------------------
    // C
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'C';    RightCtx:'. ';   Phonemes:'SS IY3'),
    (LeftCtx:' '; Letters:'CAN';  RightCtx:' ';    Phonemes:'KK AE NN'),
    (LeftCtx:' '; Letters:'CAN''T';RightCtx:' ';   Phonemes:'KK AE NN TT'),
    (LeftCtx:' '; Letters:'COULD';RightCtx:' ';    Phonemes:'KK UH DD'),
    (LeftCtx:'';  Letters:'COMPUT';RightCtx:'+';   Phonemes:'KK AH MM PP YY UW3 TT'),
    (LeftCtx:'';  Letters:'CONSIST';RightCtx:'';   Phonemes:'KK AH NN SS IH3 SS TT'),
    (LeftCtx:'';  Letters:'COMMODORE';RightCtx:''; Phonemes:'KK AA3 MM AX DD OH RR'),
    (LeftCtx:'';  Letters:'CERTAIN';RightCtx:'';   Phonemes:'SS ER3 TT IH NN'),
    (LeftCtx:'';  Letters:'CONTOUR';RightCtx:'';   Phonemes:'KK AA3 NN TT UH1 RR'),
    (LeftCtx:'';  Letters:'CO';   RightCtx:'NSOL'; Phonemes:'KK AA4'),
    (LeftCtx:'';  Letters:'COLLE';RightCtx:'C';    Phonemes:'KK UH LL EH'),
    (LeftCtx:' '; Letters:'COS';  RightCtx:' ';    Phonemes:'KK OW3 SS AY1 NN'),
    (LeftCtx:'^'; Letters:'CH';   RightCtx:'';     Phonemes:'KK'),
    (LeftCtx:'';  Letters:'CHA';  RightCtx:'R#';   Phonemes:'KK EH3'),
    (LeftCtx:'^E';Letters:'CH';   RightCtx:'';     Phonemes:'KK'),
    (LeftCtx:'';  Letters:'CH';   RightCtx:'';     Phonemes:'CH'),
    (LeftCtx:'S'; Letters:'CI';   RightCtx:'#';    Phonemes:'SS AY3'),
    (LeftCtx:'';  Letters:'CI';   RightCtx:'A';    Phonemes:'SH'),
    (LeftCtx:'';  Letters:'CI';   RightCtx:'O';    Phonemes:'SH'),
    (LeftCtx:'';  Letters:'CI';   RightCtx:'EN';   Phonemes:'SH'),
    (LeftCtx:'';  Letters:'CITY'; RightCtx:'';     Phonemes:'SS IH TT IY'),
    (LeftCtx:'';  Letters:'CIA';  RightCtx:'';     Phonemes:'SS IH AX'),
    (LeftCtx:'';  Letters:'C';    RightCtx:'+';    Phonemes:'SS'),
    (LeftCtx:'';  Letters:'CK';   RightCtx:'';     Phonemes:'KK'),
    (LeftCtx:'';  Letters:'COM';  RightCtx:'^';    Phonemes:'KK UH MM'),
    (LeftCtx:'';  Letters:'COM';  RightCtx:'%';    Phonemes:'KK AH MM'),
    (LeftCtx:'';  Letters:'CUIT'; RightCtx:'';     Phonemes:'KK IH TT'),
    (LeftCtx:'';  Letters:'CREA'; RightCtx:'^+';   Phonemes:'KK RR IY EY3'),
    (LeftCtx:'';  Letters:'CC';   RightCtx:'+';    Phonemes:'KK SS'),
    (LeftCtx:'';  Letters:'CC';   RightCtx:'';     Phonemes:'KK'),
    (LeftCtx:'';  Letters:'C';    RightCtx:'';     Phonemes:'KK'),

    // -------------------------------------------------------
    // D
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'DR.';  RightCtx:' ';    Phonemes:'DD AA3 KK TT ER'),
    (LeftCtx:' '; Letters:'D';    RightCtx:'. ';   Phonemes:'DD IY3'),
    (LeftCtx:'#'; Letters:'DED';  RightCtx:' ';    Phonemes:'DD IH DD'),
    (LeftCtx:'.E';Letters:'D';    RightCtx:'';     Phonemes:'DD'),
    (LeftCtx:'#:^E';Letters:'D';  RightCtx:'';     Phonemes:'TT'),
    (LeftCtx:' '; Letters:'DE';   RightCtx:'^#';   Phonemes:'DD IH'),
    (LeftCtx:' '; Letters:'DO';   RightCtx:' ';    Phonemes:'DD UW'),
    (LeftCtx:' '; Letters:'DOES'; RightCtx:'';     Phonemes:'DD AH ZZ'),
    (LeftCtx:' '; Letters:'DID';  RightCtx:'';     Phonemes:'DD IH DD'),
    (LeftCtx:' '; Letters:'DONE'; RightCtx:' ';    Phonemes:'DD AH5 NN'),
    (LeftCtx:' '; Letters:'DOING';RightCtx:'';     Phonemes:'DD UW3 IH NX'),
    (LeftCtx:' '; Letters:'DOW';  RightCtx:'';     Phonemes:'DD AW2'),
    (LeftCtx:'#'; Letters:'DU';   RightCtx:'A';    Phonemes:'JH UW'),
    (LeftCtx:'';  Letters:'DUC';  RightCtx:'+';    Phonemes:'DD UW SS'),
    (LeftCtx:'#'; Letters:'DU';   RightCtx:'^#';   Phonemes:'JH AX'),
    (LeftCtx:'';  Letters:'DOLLAR';RightCtx:'';    Phonemes:'DD AA3 LL ER'),
    (LeftCtx:'';  Letters:'DIA';  RightCtx:'GR';   Phonemes:'DD AY3 AH'),
    (LeftCtx:'';  Letters:'DIA';  RightCtx:'M';    Phonemes:'DD AY AE3'),
    (LeftCtx:'';  Letters:'DISTANC';RightCtx:'#';  Phonemes:'DD IH3 SS TT IH NN SS'),
    (LeftCtx:'';  Letters:'DISKETTE';RightCtx:'';  Phonemes:'DD IH SS KK EH4 TT'),
    (LeftCtx:' '; Letters:'DIS';  RightCtx:'^:#';  Phonemes:'DD IH SS'),
    (LeftCtx:'D';Letters:'D';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'DG';   RightCtx:'';     Phonemes:'JH'),
    (LeftCtx:'';  Letters:'D';    RightCtx:'';     Phonemes:'DD'),

    // -------------------------------------------------------
    // E
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'E';    RightCtx:' ';    Phonemes:'IY4'),
    (LeftCtx:'#'; Letters:'E';    RightCtx:' ';    Phonemes:''),
    (LeftCtx:''':^';Letters:'E';  RightCtx:' ';    Phonemes:''),
    (LeftCtx:' '; Letters:'E';    RightCtx:' ';    Phonemes:'IY'),
    (LeftCtx:'#'; Letters:'ED';   RightCtx:' ';    Phonemes:'DD'),
    (LeftCtx:'#:';Letters:'E';    RightCtx:'D ';   Phonemes:''),
    (LeftCtx:'';  Letters:'EV';   RightCtx:'ER';   Phonemes:'EH3 VV'),
    (LeftCtx:'#'; Letters:'ERED'; RightCtx:' ';    Phonemes:'ER DD'),
    (LeftCtx:'#'; Letters:'ERING';RightCtx:'';     Phonemes:'ER IH NX'),
    (LeftCtx:'#'; Letters:'EN';   RightCtx:' ';    Phonemes:'EH NN'),
    (LeftCtx:'#'; Letters:'ENED'; RightCtx:' ';    Phonemes:'IH NN DD'),
    (LeftCtx:'#'; Letters:'ENESS';RightCtx:' ';    Phonemes:'NN IH SS'),
    (LeftCtx:'';  Letters:'EXA';  RightCtx:'M';    Phonemes:'IH GG ZZ AE3'),
    (LeftCtx:'';  Letters:'EXA';  RightCtx:'C';    Phonemes:'IH GG ZZ AE3'),
    (LeftCtx:'';  Letters:'EDGE'; RightCtx:'';     Phonemes:'EH JH'),
    (LeftCtx:'';  Letters:'ENG';  RightCtx:'LISH'; Phonemes:'IY3 NX GG'),
    (LeftCtx:' '; Letters:'ETC';  RightCtx:' ';    Phonemes:'EH TT SS EH3 TT RR AH'),
    (LeftCtx:'';  Letters:'E';    RightCtx:'^%';   Phonemes:'IY3'),
    (LeftCtx:'';  Letters:'ERI';  RightCtx:'#';    Phonemes:'IY3 RR IY'),
    (LeftCtx:'';  Letters:'ERI';  RightCtx:'';     Phonemes:'EH3 RR IH'),
    (LeftCtx:'#'; Letters:'ER';   RightCtx:'#';    Phonemes:'ER'),
    (LeftCtx:'';  Letters:'ERROR';RightCtx:'';     Phonemes:'EH3 RR OH RR'),
    (LeftCtx:'';  Letters:'ERAS'; RightCtx:'#';    Phonemes:'IH RR EY3 SS'),
    (LeftCtx:'';  Letters:'ER';   RightCtx:'#';    Phonemes:'EH1 RR'),
    (LeftCtx:'#'; Letters:'ER';   RightCtx:' ';    Phonemes:'ER'),
    (LeftCtx:'#'; Letters:'ERS';  RightCtx:' ';    Phonemes:'ER ZZ'),
    (LeftCtx:'';  Letters:'ER';   RightCtx:'';     Phonemes:'ER'),
    (LeftCtx:'';  Letters:'EVEN'; RightCtx:' ';    Phonemes:'IY3 VV IH NN'),
    (LeftCtx:' '; Letters:'EVEN'; RightCtx:'';     Phonemes:'IY VV EH3 NN'),
    (LeftCtx:'#'; Letters:'E';    RightCtx:'W';    Phonemes:''),
    (LeftCtx:'@'; Letters:'EW';   RightCtx:'';     Phonemes:'UW'),
    (LeftCtx:'';  Letters:'EW';   RightCtx:'';     Phonemes:'YY UW'),
    (LeftCtx:'';  Letters:'E';    RightCtx:'O';    Phonemes:'IY'),
    (LeftCtx:'SH';Letters:'ES';   RightCtx:' ';    Phonemes:'IH ZZ'),
    (LeftCtx:'CH';Letters:'ES';   RightCtx:' ';    Phonemes:'IH ZZ'),
    (LeftCtx:'#:&';Letters:'ES';  RightCtx:' ';    Phonemes:'IH ZZ'),
    (LeftCtx:'#'; Letters:'E';    RightCtx:'S ';   Phonemes:''),
    (LeftCtx:'#'; Letters:'ELY';  RightCtx:' ';    Phonemes:'LL IY'),
    (LeftCtx:'#'; Letters:'EMENT';RightCtx:'';     Phonemes:'MM IH NN TT'),
    (LeftCtx:'';  Letters:'EFUL'; RightCtx:'';     Phonemes:'FF UH LL'),
    (LeftCtx:'';  Letters:'EE';   RightCtx:'';     Phonemes:'IY'),
    (LeftCtx:'';  Letters:'EARN'; RightCtx:'';     Phonemes:'ER3 NN'),
    (LeftCtx:' '; Letters:'EAR';  RightCtx:'^';    Phonemes:'ER3'),
    (LeftCtx:'';  Letters:'EAD';  RightCtx:'';     Phonemes:'EH DD'),
    (LeftCtx:'#'; Letters:'EA';   RightCtx:' ';    Phonemes:'IY AH'),
    (LeftCtx:'M'; Letters:'EA';   RightCtx:'S';    Phonemes:'EH'),
    (LeftCtx:'L'; Letters:'EA';   RightCtx:'S';    Phonemes:'EH'),
    (LeftCtx:'';  Letters:'EA';   RightCtx:'SU';   Phonemes:'EH3'),
    (LeftCtx:'';  Letters:'EA';   RightCtx:'';     Phonemes:'IY'),
    (LeftCtx:'';  Letters:'EIGH'; RightCtx:'';     Phonemes:'EY3'),
    (LeftCtx:'';  Letters:'EI';   RightCtx:'';     Phonemes:'IY'),
    (LeftCtx:' '; Letters:'EYE';  RightCtx:'';     Phonemes:'AY3'),
    (LeftCtx:'';  Letters:'EY';   RightCtx:'';     Phonemes:'IY'),
    (LeftCtx:'';  Letters:'EU';   RightCtx:'';     Phonemes:'YY UW'),
    (LeftCtx:'';  Letters:'E';    RightCtx:'TION'; Phonemes:'IY3'),
    (LeftCtx:'';  Letters:'E';    RightCtx:'SION'; Phonemes:'IY3'),
    (LeftCtx:'';  Letters:'EQUAL';RightCtx:'';     Phonemes:'IY3 KK WW UL'),
    (LeftCtx:'#'; Letters:'E';    RightCtx:'^#';   Phonemes:'IH'),
    (LeftCtx:'';  Letters:'E';    RightCtx:'#';    Phonemes:'IY'),
    (LeftCtx:'#:^'; Letters:'E'; RightCtx:' ';  Phonemes:''),          // VCE magic-E: love→LL AH VV, give→GG IH VV, choice→CH OY SS
                                                                        //   Left context (right-to-left): ^=one consonant, :=any more consonants, #=a vowel
                                                                        //   Right context: word boundary. Silences the final E.
                                                                        //   Vowel lengthening (fate→EY, time→AY, Rome→OW) is handled by
                                                                        //   the A/I/O/E + ^% rules earlier in their respective sections.
    // Syllabic N: VCen word-final → UN.  kitten, written, broken, open, even, happen.
    // Must come before magic-E rule because EN is two characters; the engine
    // consumes both E and N in one step, leaving no dangling E to silence.
    (LeftCtx:'#:^'; Letters:'EN'; RightCtx:' ';  Phonemes:'UN'),
    // Syllabic L: VCel word-final → UL.  travel, model, vowel, novel, channel.
    (LeftCtx:'#:^'; Letters:'EL'; RightCtx:' ';  Phonemes:'UL'),
    (LeftCtx:'';    Letters:'E'; RightCtx:'';   Phonemes:'EH'),        // default

    // -------------------------------------------------------
    // F
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'F';    RightCtx:'. ';   Phonemes:'EH3 FF'),
    (LeftCtx:' '; Letters:'FOR';  RightCtx:' ';    Phonemes:'FF AO RR'),
    (LeftCtx:' '; Letters:'FROM'; RightCtx:' ';    Phonemes:'FF RR AH MM'),
    (LeftCtx:' '; Letters:'FT.';  RightCtx:' ';    Phonemes:'FF IY3 TT'),
    (LeftCtx:'';  Letters:'FUL';  RightCtx:'';     Phonemes:'FF UH LL'),
    (LeftCtx:'';  Letters:'FRIEND';RightCtx:'';    Phonemes:'FF RR EH3 NN DD'),
    (LeftCtx:'';  Letters:'FE';   RightCtx:'MALE'; Phonemes:'FF IY3'),
    (LeftCtx:'';  Letters:'FORGET';RightCtx:'';    Phonemes:'FF OH RR GG EH3 TT'),
    (LeftCtx:'';  Letters:'FUNC'; RightCtx:'^';    Phonemes:'FF AH4 NX KK'),
    (LeftCtx:'';  Letters:'FATHER';RightCtx:'';    Phonemes:'FF AA3 DH ER'),
    (LeftCtx:'F';Letters:'F';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'F';    RightCtx:'';     Phonemes:'FF'),

    // -------------------------------------------------------
    // G
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'G';    RightCtx:'. ';   Phonemes:'JH IY3'),
    (LeftCtx:'';  Letters:'GIV';  RightCtx:'';     Phonemes:'GG IH3 VV'),
    (LeftCtx:' '; Letters:'G';    RightCtx:'I^';   Phonemes:'GG'),
    (LeftCtx:' '; Letters:'GET';  RightCtx:' ';    Phonemes:'GG EH TT'),
    (LeftCtx:'';  Letters:'GE';   RightCtx:'T';    Phonemes:'GG EH'),
    (LeftCtx:'SU';Letters:'GGES'; RightCtx:'';     Phonemes:'GG JH EH3 SS'),
    (LeftCtx:'';  Letters:'GION'; RightCtx:'';     Phonemes:'JH UH NN'),
    (LeftCtx:'';  Letters:'GG';   RightCtx:'';     Phonemes:'GG'),
    (LeftCtx:'B#';Letters:'G';    RightCtx:'';     Phonemes:'GG'),
    (LeftCtx:'';  Letters:'G';    RightCtx:'+';    Phonemes:'JH'),
    (LeftCtx:'';  Letters:'GREAT';RightCtx:'';     Phonemes:'GG RR EY3 TT'),
    (LeftCtx:' '; Letters:'GO';   RightCtx:' ';    Phonemes:'GG OW'),
    (LeftCtx:'';  Letters:'GON';  RightCtx:'E';    Phonemes:'GG AA3 NN'),
    (LeftCtx:'#'; Letters:'GH';   RightCtx:'';     Phonemes:''),
    (LeftCtx:' '; Letters:'GH';   RightCtx:'';     Phonemes:'GG'),
    (LeftCtx:'';  Letters:'GH';   RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'GN';   RightCtx:'';     Phonemes:'NN'),
    (LeftCtx:'';  Letters:'G';    RightCtx:'';     Phonemes:'GG'),

    // -------------------------------------------------------
    // H
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'H';    RightCtx:'. ';   Phonemes:'EY4 CH'),
    (LeftCtx:' '; Letters:'HAVE'; RightCtx:' ';    Phonemes:'HH AE VV'),
    (LeftCtx:'';  Letters:'HAV';  RightCtx:'';     Phonemes:'HH AE VV'),
    (LeftCtx:' '; Letters:'HAS';  RightCtx:' ';    Phonemes:'HH AE ZZ'),
    (LeftCtx:' '; Letters:'HAD';  RightCtx:' ';    Phonemes:'HH AE DD'),
    (LeftCtx:' '; Letters:'HE';   RightCtx:' ';    Phonemes:'HH IY'),
    (LeftCtx:' '; Letters:'HIS';  RightCtx:' ';    Phonemes:'HH IH ZZ'),
    (LeftCtx:' '; Letters:'HER';  RightCtx:' ';    Phonemes:'HH ER'),
    (LeftCtx:' '; Letters:'HE''LL';RightCtx:' ';   Phonemes:'HH IY LL'),
    (LeftCtx:' '; Letters:'HE''D'; RightCtx:' ';   Phonemes:'HH IY DD'),
    (LeftCtx:'';  Letters:'HERE'; RightCtx:'';     Phonemes:'HH IY RR'),
    (LeftCtx:'';  Letters:'HOUR'; RightCtx:'';     Phonemes:'AW3 ER'),
    (LeftCtx:' '; Letters:'HOW';  RightCtx:'';     Phonemes:'HH AW'),
    (LeftCtx:'';  Letters:'H';    RightCtx:'#';    Phonemes:'HH'),
    (LeftCtx:'';  Letters:'H';    RightCtx:'';     Phonemes:''),

    // -------------------------------------------------------
    // I
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'IN';   RightCtx:' ';    Phonemes:'IH NN'),
    (LeftCtx:' '; Letters:'IBM';  RightCtx:'';     Phonemes:'AY3 BB IY EH3 MM'),
    (LeftCtx:' '; Letters:'INPUT';RightCtx:'';     Phonemes:'IH4 NN PP UH1 TT'),
    (LeftCtx:' '; Letters:'IN';   RightCtx:'';     Phonemes:'IX NN'),
    (LeftCtx:'#'; Letters:'I';    RightCtx:'NG';   Phonemes:'IH'),
    (LeftCtx:' '; Letters:'IS';   RightCtx:' ';    Phonemes:'IH ZZ'),
    (LeftCtx:' '; Letters:'IF';   RightCtx:' ';    Phonemes:'IH FF'),
    (LeftCtx:' '; Letters:'INTO'; RightCtx:' ';    Phonemes:'IH2 NN TT UW'),
    (LeftCtx:' '; Letters:'I';    RightCtx:' ';    Phonemes:'AY'),
    (LeftCtx:' '; Letters:'IT';   RightCtx:' ';    Phonemes:'IH TT'),
    (LeftCtx:' '; Letters:'ITS';  RightCtx:' ';    Phonemes:'IH TT SS'),
    (LeftCtx:' '; Letters:'IT''S'; RightCtx:' ';   Phonemes:'IH TT SS'),
    (LeftCtx:' '; Letters:'IT''D'; RightCtx:' ';   Phonemes:'IH TT IX DD'),
    (LeftCtx:' '; Letters:'I''M'; RightCtx:' ';    Phonemes:'AY MM'),
    (LeftCtx:' '; Letters:'I''D'; RightCtx:' ';    Phonemes:'AY DD'),
    (LeftCtx:' '; Letters:'I''VE';RightCtx:' ';    Phonemes:'AY VV'),
    (LeftCtx:' '; Letters:'I''LL';RightCtx:' ';    Phonemes:'AY LL'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'TION'; Phonemes:'IH3'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'SION'; Phonemes:'IH3'),
    (LeftCtx:'';  Letters:'I';    RightCtx:' ';    Phonemes:'AY'),
    (LeftCtx:'';  Letters:'IN';   RightCtx:'D';    Phonemes:'AY NN'),
    (LeftCtx:'SEM';Letters:'I';   RightCtx:'';     Phonemes:'IY'),
    (LeftCtx:'ANT';Letters:'I';   RightCtx:'';     Phonemes:'AY'),
    (LeftCtx:'';  Letters:'IER';  RightCtx:'';     Phonemes:'IY ER'),
    (LeftCtx:'#:R';Letters:'IED'; RightCtx:' ';    Phonemes:'IY DD'),
    (LeftCtx:'';  Letters:'IED';  RightCtx:' ';    Phonemes:'AY DD'),
    (LeftCtx:'';  Letters:'IEN';  RightCtx:'';     Phonemes:'IY EH NN'),
    (LeftCtx:'';  Letters:'IE';   RightCtx:'T';    Phonemes:'AY EH'),
    (LeftCtx:'';  Letters:'IE';   RightCtx:'';     Phonemes:'IY3'),
    (LeftCtx:' '; Letters:'I';    RightCtx:'^%';   Phonemes:'AY'),
    (LeftCtx:' '; Letters:'I';    RightCtx:'%';    Phonemes:'AY'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'%';    Phonemes:'IY'),
    (LeftCtx:' '; Letters:'IDEA'; RightCtx:'';     Phonemes:'AY DD IY3 AH'),
    (LeftCtx:' '; Letters:'ISLAND';RightCtx:'';    Phonemes:'AY3 LL IH NN DD'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'^+:#'; Phonemes:'IH'),
    (LeftCtx:'#'; Letters:'I';    RightCtx:'^AL';  Phonemes:'IH'),
    (LeftCtx:'';  Letters:'IR';   RightCtx:'#';    Phonemes:'AY1 RR'),
    (LeftCtx:'';  Letters:'IZ';   RightCtx:'%';    Phonemes:'AY1 ZZ'),
    (LeftCtx:'';  Letters:'IS';   RightCtx:'%';    Phonemes:'AY3 ZZ'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'D%';   Phonemes:'AY3'),
    (LeftCtx:'#'; Letters:'ITY';  RightCtx:' ';    Phonemes:'IH TT IY'),
    (LeftCtx:'I^';Letters:'I';    RightCtx:'^#';   Phonemes:'IH'),
    (LeftCtx:'+^';Letters:'I';    RightCtx:'^+';   Phonemes:'AY3'),
    (LeftCtx:'#:^';Letters:'I';   RightCtx:'^%';   Phonemes:'AY3'),
    (LeftCtx:'#:^';Letters:'I';   RightCtx:'^+';   Phonemes:'IH'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'^+';   Phonemes:'AY'),
    (LeftCtx:'';  Letters:'IR';   RightCtx:'';     Phonemes:'ER'),
    (LeftCtx:'';  Letters:'IGH';  RightCtx:'';     Phonemes:'AY3'),
    (LeftCtx:'';  Letters:'ILD';  RightCtx:'';     Phonemes:'AY3 LL DD'),
    (LeftCtx:' '; Letters:'IGN';  RightCtx:'';     Phonemes:'IX GG NN'),
    (LeftCtx:'';  Letters:'IGN';  RightCtx:' ';    Phonemes:'AY3 NN'),
    (LeftCtx:'';  Letters:'IGN';  RightCtx:'^';    Phonemes:'AY3 NN'),
    (LeftCtx:'';  Letters:'IGN';  RightCtx:'%';    Phonemes:'AY3 NN'),
    (LeftCtx:'#'; Letters:'IC';   RightCtx:' ';    Phonemes:'IH KK'),
    (LeftCtx:'';  Letters:'ICRO'; RightCtx:'';     Phonemes:'AY3 KK RR OW'),
    (LeftCtx:'';  Letters:'IQUE'; RightCtx:'';     Phonemes:'IY3 KK'),
    // Syllabic L: VCil word-final → UL.  pencil, council, fossil, April, nostril.
    (LeftCtx:'#:^'; Letters:'IL'; RightCtx:' ';  Phonemes:'UL'),
    // Syllabic N: VCin word-final → UN.  cabin, cousin, robin, satin, raisin, origin.
    (LeftCtx:'#:^'; Letters:'IN'; RightCtx:' ';  Phonemes:'UN'),
    (LeftCtx:'';  Letters:'I';    RightCtx:'';     Phonemes:'IH'),

    // -------------------------------------------------------
    // J
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'JUST'; RightCtx:'';     Phonemes:'JH AH SS TT'),
    (LeftCtx:'';  Letters:'JOSE'; RightCtx:'PH';   Phonemes:'JH OW SS IH'),
    (LeftCtx:'J';Letters:'J';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'J';    RightCtx:'';     Phonemes:'JH'),

    // -------------------------------------------------------
    // K
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'K';    RightCtx:'. ';   Phonemes:'KK EY3'),
    (LeftCtx:'';  Letters:'KNOW'; RightCtx:'L';    Phonemes:'NN AA3'),
    (LeftCtx:' '; Letters:'K';    RightCtx:'N';    Phonemes:''),
    (LeftCtx:'K';Letters:'K';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'K';    RightCtx:'';     Phonemes:'KK'),

    // -------------------------------------------------------
    // L
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'L';    RightCtx:'. ';   Phonemes:'EH4 LL'),
    (LeftCtx:' '; Letters:'LIKE'; RightCtx:'';     Phonemes:'LL AY KK'),
    (LeftCtx:' '; Letters:'LIV';  RightCtx:'ELY';  Phonemes:'LL AY3 VV'),
    (LeftCtx:' '; Letters:'LIV';  RightCtx:'%';    Phonemes:'LL IH3 VV'),
    (LeftCtx:' '; Letters:'LIV';  RightCtx:'ING';  Phonemes:'LL IH3 VV'),
    (LeftCtx:'';  Letters:'LEVEL';RightCtx:'';     Phonemes:'LL EH3 VV UL'),
    (LeftCtx:' '; Letters:'LOS';  RightCtx:'%';    Phonemes:'LL UW3 ZZ'),
    (LeftCtx:'';  Letters:'LISTEN';RightCtx:'';    Phonemes:'LL IH3 SS IH NN'),
    (LeftCtx:' '; Letters:'LB.';  RightCtx:' ';    Phonemes:'PP AW3 NN DD ZZ'),
    (LeftCtx:' '; Letters:'LN';   RightCtx:' ';    Phonemes:'LL AO2 GG'),
    (LeftCtx:'';  Letters:'LO';   RightCtx:'C#';   Phonemes:'LL OW'),
    (LeftCtx:'L';Letters:'L';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'#:^';Letters:'L';   RightCtx:'%';    Phonemes:'UL'),
    (LeftCtx:'';  Letters:'LEAD'; RightCtx:'';     Phonemes:'LL IY DD'),
    (LeftCtx:' '; Letters:'LAUGH';RightCtx:'';     Phonemes:'LL AE FF'),
    (LeftCtx:'';  Letters:'L';    RightCtx:'';     Phonemes:'LL'),

    // -------------------------------------------------------
    // M
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'ME';   RightCtx:' ';    Phonemes:'MM IY'),
    (LeftCtx:' '; Letters:'MAY';  RightCtx:' ';    Phonemes:'MM EY'),
    (LeftCtx:' '; Letters:'MY';   RightCtx:' ';    Phonemes:'MM AY'),
    (LeftCtx:' '; Letters:'MIGHT';RightCtx:' ';    Phonemes:'MM AY TT'),
    (LeftCtx:' '; Letters:'MUST'; RightCtx:'';     Phonemes:'MM AH SS TT'),
    (LeftCtx:' '; Letters:'MINE'; RightCtx:' ';    Phonemes:'MM AY4 NN'),
    (LeftCtx:'';  Letters:'MINE'; RightCtx:' ';    Phonemes:'MM IH NN'),
    (LeftCtx:'';  Letters:'MACINTO';RightCtx:'SH'; Phonemes:'MM AE5 KK IH NN TT AA1'),
    (LeftCtx:'';  Letters:'MACINTAL';RightCtx:'K'; Phonemes:'MM AE5 KK IH NN TT AO1'),
    (LeftCtx:'';  Letters:'MOUS'; RightCtx:'#';    Phonemes:'MM AW3 SS'),
    (LeftCtx:'';  Letters:'MAJ';  RightCtx:'OR ';  Phonemes:'MM EY3 JH'),
    (LeftCtx:' '; Letters:'MR.';  RightCtx:' ';    Phonemes:'MM IH2 SS TT ER'),
    (LeftCtx:' '; Letters:'MS.';  RightCtx:'';     Phonemes:'MM IH2 ZZ'),
    (LeftCtx:' '; Letters:'MRS.'; RightCtx:' ';    Phonemes:'MM IH2 SS IX ZZ'),
    (LeftCtx:' '; Letters:'MI.';  RightCtx:' ';    Phonemes:'MM AY4 LL ZZ'),
    (LeftCtx:' '; Letters:'M';    RightCtx:'. ';   Phonemes:'EH3 MM'),
    (LeftCtx:'';  Letters:'MOV';  RightCtx:'';     Phonemes:'MM UW3 VV'),
    (LeftCtx:'';  Letters:'MACHIN';RightCtx:'';    Phonemes:'MM AH SH IY3 NN'),
    (LeftCtx:'M';Letters:'M';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'M';    RightCtx:'';     Phonemes:'MM'),

    // -------------------------------------------------------
    // N
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'N';    RightCtx:'. ';   Phonemes:'EH4 NN'),
    (LeftCtx:'E'; Letters:'NG';   RightCtx:'+';    Phonemes:'NJ'),
    (LeftCtx:'';  Letters:'NG';   RightCtx:'R';    Phonemes:'NX GG'),
    (LeftCtx:'';  Letters:'NG';   RightCtx:'#';    Phonemes:'NX GG'),
    (LeftCtx:'';  Letters:'NGL';  RightCtx:'%';    Phonemes:'NX GG UL'),
    (LeftCtx:'';  Letters:'NG';   RightCtx:'';     Phonemes:'NX'),
    (LeftCtx:'';  Letters:'NK';   RightCtx:'';     Phonemes:'NX KK'),
    (LeftCtx:' '; Letters:'NOW';  RightCtx:' ';    Phonemes:'NN AW'),
    (LeftCtx:'N';Letters:'N';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'NOTIC';RightCtx:'+';    Phonemes:'NN OW4 TT IH SS'),
    (LeftCtx:' '; Letters:'NO';   RightCtx:' ';    Phonemes:'NN OW'),
    (LeftCtx:' '; Letters:'NOT';  RightCtx:' ';    Phonemes:'NN AA TT'),
    (LeftCtx:'';  Letters:'NON';  RightCtx:'E';    Phonemes:'NN AH NN'),
    (LeftCtx:'';  Letters:'NEU';  RightCtx:'';     Phonemes:'NN UW'),
    (LeftCtx:'';  Letters:'N';    RightCtx:'';     Phonemes:'NN'),

    // -------------------------------------------------------
    // O
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'O';    RightCtx:' ';    Phonemes:'OW3'),
    (LeftCtx:'';  Letters:'OF';   RightCtx:' ';    Phonemes:'AH VV'),
    (LeftCtx:' '; Letters:'OFF';  RightCtx:' ';    Phonemes:'AO FF'),
    (LeftCtx:' '; Letters:'ON';   RightCtx:' ';    Phonemes:'AA NN'),
    (LeftCtx:' '; Letters:'OH';   RightCtx:'';     Phonemes:'OW5'),
    (LeftCtx:'';  Letters:'OROUGH';RightCtx:'';    Phonemes:'ER3 OW'),
    (LeftCtx:' '; Letters:'OZ.';  RightCtx:' ';    Phonemes:'AW2 NN SS IH ZZ'),
    (LeftCtx:' '; Letters:'OR';   RightCtx:' ';    Phonemes:'OH RR'),
    (LeftCtx:'';  Letters:'OR';   RightCtx:' ';    Phonemes:'ER'),
    (LeftCtx:'#'; Letters:'ORS';  RightCtx:' ';    Phonemes:'ER ZZ'),
    (LeftCtx:'';  Letters:'OR';   RightCtx:'';     Phonemes:'OH RR'),
    (LeftCtx:' '; Letters:'ONE';  RightCtx:'';     Phonemes:'WW AH3 NN'),
    (LeftCtx:'#'; Letters:'ONE';  RightCtx:' ';    Phonemes:'WW AH1 NN'),
    (LeftCtx:'';  Letters:'OW';   RightCtx:'';     Phonemes:'OW'),
    (LeftCtx:' '; Letters:'OVER'; RightCtx:'';     Phonemes:'OW VV ER'),
    (LeftCtx:'R'; Letters:'O';    RightCtx:'L';    Phonemes:'OH2'),
    (LeftCtx:'PR';Letters:'O';    RightCtx:'V%';   Phonemes:'UW3'),
    (LeftCtx:'PR';Letters:'O';    RightCtx:'VING'; Phonemes:'UW3'),
    (LeftCtx:'PR';Letters:'O';    RightCtx:'V';    Phonemes:'OH'),
    (LeftCtx:'';  Letters:'OV';   RightCtx:'';     Phonemes:'AH VV'),
    (LeftCtx:'';  Letters:'OL';   RightCtx:'K';    Phonemes:'OW'),
    (LeftCtx:'';  Letters:'OL';   RightCtx:'T';    Phonemes:'OH LL'),
    (LeftCtx:'';  Letters:'OL';   RightCtx:'D';    Phonemes:'OH LL'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'TION'; Phonemes:'OW3'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'SION'; Phonemes:'OW3'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'^%';   Phonemes:'OW'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'^EN';  Phonemes:'OW'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'^I#';  Phonemes:'OW'),
    (LeftCtx:'';  Letters:'OUGHT';RightCtx:'';     Phonemes:'AO3 TT'),
    (LeftCtx:'';  Letters:'OUGH'; RightCtx:'';     Phonemes:'AH3 FF'),
    (LeftCtx:' '; Letters:'OU';   RightCtx:'';     Phonemes:'AW'),
    (LeftCtx:'H'; Letters:'OU';   RightCtx:'S#';   Phonemes:'AW3'),
    (LeftCtx:'';  Letters:'OUS';  RightCtx:'';     Phonemes:'AX SS'),
    (LeftCtx:'';  Letters:'OUR';  RightCtx:'';     Phonemes:'OH RR'),
    (LeftCtx:'';  Letters:'OULD'; RightCtx:'';     Phonemes:'UH DD'),
    (LeftCtx:'^'; Letters:'OU';   RightCtx:'^L';   Phonemes:'AH'),
    (LeftCtx:'';  Letters:'OUP';  RightCtx:'';     Phonemes:'UW PP'),
    (LeftCtx:'T'; Letters:'OU';   RightCtx:'CH';   Phonemes:'AH3'),
    (LeftCtx:'';  Letters:'OU';   RightCtx:'';     Phonemes:'AW'),
    (LeftCtx:'';  Letters:'OY';   RightCtx:'';     Phonemes:'OY'),
    (LeftCtx:'';  Letters:'OING'; RightCtx:'';     Phonemes:'OW3 IH NX'),
    (LeftCtx:'';  Letters:'OI';   RightCtx:'';     Phonemes:'OY4'),
    (LeftCtx:'';  Letters:'OOR';  RightCtx:'';     Phonemes:'UH RR'),
    (LeftCtx:'';  Letters:'OOK';  RightCtx:'';     Phonemes:'UH4 KK'),
    (LeftCtx:'F'; Letters:'OOD';  RightCtx:'';     Phonemes:'UW4 DD'),
    (LeftCtx:'L'; Letters:'OOD';  RightCtx:'';     Phonemes:'AH4 DD'),
    (LeftCtx:'M'; Letters:'OOD';  RightCtx:'';     Phonemes:'UW4 DD'),
    (LeftCtx:'';  Letters:'OOD';  RightCtx:'';     Phonemes:'UH4 DD'),
    (LeftCtx:'F'; Letters:'OOT';  RightCtx:'';     Phonemes:'UH4 TT'),
    (LeftCtx:'';  Letters:'OO';   RightCtx:'';     Phonemes:'UW4'),
    (LeftCtx:'';  Letters:'O''';  RightCtx:'';     Phonemes:'OH'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'E';    Phonemes:'OW'),
    (LeftCtx:'';  Letters:'O';    RightCtx:' ';    Phonemes:'OW'),
    (LeftCtx:'';  Letters:'OA';   RightCtx:'';     Phonemes:'OW'),
    (LeftCtx:' '; Letters:'ONLY'; RightCtx:'';     Phonemes:'OW3 NN LL IY'),
    (LeftCtx:' '; Letters:'ONCE'; RightCtx:'';     Phonemes:'WW AH1 NN SS'),
    (LeftCtx:'';  Letters:'ON''T';RightCtx:'';     Phonemes:'OW4 NN TT'),
    (LeftCtx:'C'; Letters:'O';    RightCtx:'N';    Phonemes:'AX'),
    (LeftCtx:'C'; Letters:'O';    RightCtx:'N';    Phonemes:'AA'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'NG';   Phonemes:'AO'),
    (LeftCtx:'N'; Letters:'O';    RightCtx:'NE';   Phonemes:'AH4'),
    (LeftCtx:'N'; Letters:'O';    RightCtx:'N';    Phonemes:'AA'),
    (LeftCtx:' :^';Letters:'O';   RightCtx:'N';    Phonemes:'AH'),
    (LeftCtx:'I'; Letters:'ON';   RightCtx:'';     Phonemes:'UN'),
    (LeftCtx:'#'; Letters:'ON';   RightCtx:' ';    Phonemes:'UN'),
    (LeftCtx:'#^';Letters:'ON';   RightCtx:'';     Phonemes:'UN'),
    (LeftCtx:'FR';Letters:'O';    RightCtx:'ST';   Phonemes:'AO4'),
    (LeftCtx:'L'; Letters:'O';    RightCtx:'ST';   Phonemes:'AO4'),
    (LeftCtx:'C'; Letters:'O';    RightCtx:'ST';   Phonemes:'AO4'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'ST%';  Phonemes:'OW4'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'ST ';  Phonemes:'OW4'),
    (LeftCtx:'';  Letters:'OF';   RightCtx:'^';    Phonemes:'AO FF'),
    (LeftCtx:'B'; Letters:'OTH';  RightCtx:'ER';   Phonemes:'AA3 DH'),
    (LeftCtx:'';  Letters:'OTHER';RightCtx:'';     Phonemes:'AH2 DH ER'),
    (LeftCtx:'R'; Letters:'O';    RightCtx:'B';    Phonemes:'AA'),
    (LeftCtx:'PR';Letters:'O';    RightCtx:':#';   Phonemes:'OW4'),
    (LeftCtx:'';  Letters:'OSS';  RightCtx:' ';    Phonemes:'AA4 SS'),
    // Syllabic M: VCom word-final → UM.  bottom, fathom, random, blossom, phantom.
    // The existing rule below handles OM mid-word (e.g. "come", "some" → AH MM).
    (LeftCtx:'#:^'; Letters:'OM'; RightCtx:' ';  Phonemes:'UM'),
    (LeftCtx:'#:^';Letters:'OM';  RightCtx:'';     Phonemes:'AH MM'),
    (LeftCtx:' '; Letters:'OK';   RightCtx:' ';    Phonemes:'OW KK EY3'),
    (LeftCtx:' '; Letters:'O.K.'; RightCtx:'';     Phonemes:'OW KK EY3'),
    (LeftCtx:'';  Letters:'O';    RightCtx:'';     Phonemes:'AA'),

    // -------------------------------------------------------
    // P
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'P';    RightCtx:'. ';   Phonemes:'PP IY3'),
    (LeftCtx:'';  Letters:'PH';   RightCtx:'';     Phonemes:'FF'),
    (LeftCtx:' '; Letters:'PUT';  RightCtx:' ';    Phonemes:'PP UH TT'),
    (LeftCtx:' '; Letters:'PUTS'; RightCtx:' ';    Phonemes:'PP UH TT SS'),
    (LeftCtx:'';  Letters:'PEOPL';RightCtx:'';     Phonemes:'PP IY3 PP UL'),
    (LeftCtx:'';  Letters:'PURPOSE';RightCtx:'';   Phonemes:'PP ER3 PP AX SS'),
    (LeftCtx:'';  Letters:'PRIOR';RightCtx:'#';    Phonemes:'PP RR AY OH4 RR'),
    (LeftCtx:'';  Letters:'PRIOR';RightCtx:'';     Phonemes:'PP RR AY4 ER'),
    (LeftCtx:'';  Letters:'PIT';  RightCtx:'CH';   Phonemes:'PP IH4'),
    (LeftCtx:'';  Letters:'POW';  RightCtx:'';     Phonemes:'PP AW4'),
    (LeftCtx:'';  Letters:'PUT';  RightCtx:' ';    Phonemes:'PP UH TT'),
    (LeftCtx:'P';Letters:'P';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'P';    RightCtx:'N';    Phonemes:''),
    (LeftCtx:'';  Letters:'P';    RightCtx:'S';    Phonemes:''),
    (LeftCtx:'';  Letters:'PERSON';RightCtx:'';    Phonemes:'PP ER3 SS UH NN'),
    (LeftCtx:' '; Letters:'PROF.';RightCtx:'';     Phonemes:'PP RR OH FF EH3 SS ER'),
    (LeftCtx:' '; Letters:'PS';   RightCtx:'';     Phonemes:'SS'),
    (LeftCtx:'';  Letters:'P';    RightCtx:'';     Phonemes:'PP'),

    // -------------------------------------------------------
    // Q
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'Q';    RightCtx:'. ';   Phonemes:'KK YY UW3'),
    (LeftCtx:'S'; Letters:'QUAR'; RightCtx:'';     Phonemes:'KK WW EH4 RR'),
    (LeftCtx:'';  Letters:'QUAR'; RightCtx:'';     Phonemes:'KK WW OH4 RR'),
    (LeftCtx:'';  Letters:'QUA';  RightCtx:'L';    Phonemes:'KK WW AA4'),
    (LeftCtx:'';  Letters:'QU';   RightCtx:'';     Phonemes:'KK WW'),
    (LeftCtx:'Q';Letters:'Q';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'Q';    RightCtx:'';     Phonemes:'KK'),

    // -------------------------------------------------------
    // R
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'R';    RightCtx:'. ';   Phonemes:'AA3 RR'),
    (LeftCtx:'';  Letters:'READY';RightCtx:'';     Phonemes:'RR EH3 DD IY'),
    (LeftCtx:'';  Letters:'READ'; RightCtx:'';     Phonemes:'RR IY4 DD'),
    (LeftCtx:'';  Letters:'ROUTINE';RightCtx:'';   Phonemes:'RR UW TT IY4 NN'),
    (LeftCtx:'';  Letters:'REPLY';RightCtx:'';     Phonemes:'RR IH PP LL AY4'),
    (LeftCtx:' '; Letters:'RE';   RightCtx:'^#';   Phonemes:'RR IY'),
    (LeftCtx:'R';Letters:'R';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'R';    RightCtx:'';     Phonemes:'RR'),

    // -------------------------------------------------------
    // S
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'S';    RightCtx:'. ';   Phonemes:'EH3 SS'),
    (LeftCtx:' '; Letters:'SO';   RightCtx:' ';    Phonemes:'SS OW'),
    (LeftCtx:'';  Letters:'SH';   RightCtx:'';     Phonemes:'SH'),
    (LeftCtx:'#'; Letters:'SION'; RightCtx:'';     Phonemes:'ZH UH NN'),
    (LeftCtx:'';  Letters:'SOME'; RightCtx:'';     Phonemes:'SS AH MM'),
    (LeftCtx:'#'; Letters:'SUR';  RightCtx:'#';    Phonemes:'ZH ER'),
    (LeftCtx:'';  Letters:'SUR';  RightCtx:'#';    Phonemes:'SH ER'),
    (LeftCtx:'#'; Letters:'SU';   RightCtx:'#';    Phonemes:'ZH UW'),
    (LeftCtx:'#'; Letters:'SSU';  RightCtx:'#';    Phonemes:'SH UW'),
    (LeftCtx:'#'; Letters:'SED';  RightCtx:' ';    Phonemes:'ZZ DD'),
    (LeftCtx:'';  Letters:'SIS';  RightCtx:'';     Phonemes:'SS IH SS'),
    (LeftCtx:' '; Letters:'ST.';  RightCtx:' ';    Phonemes:'SS TT RR IY2 TT'),
    (LeftCtx:'';  Letters:'SOFTVOICE';RightCtx:''; Phonemes:'SS AA4 FF TT VV OY SS'),
    (LeftCtx:'#'; Letters:'S';    RightCtx:'#';    Phonemes:'ZZ'),
    (LeftCtx:'';  Letters:'SINCE';RightCtx:'';     Phonemes:'SS IH NN SS'),
    (LeftCtx:'';  Letters:'SUCH'; RightCtx:'';     Phonemes:'SS AH CH'),
    (LeftCtx:'';  Letters:'SAID'; RightCtx:'';     Phonemes:'SS EH DD'),
    (LeftCtx:'';  Letters:'SAYS'; RightCtx:'';     Phonemes:'SS EH ZZ'),
    (LeftCtx:'';  Letters:'SEVEN';RightCtx:'';     Phonemes:'SS EH3 VV IH NN'),
    (LeftCtx:'';  Letters:'SURFAC';RightCtx:'#';   Phonemes:'SS ER3 FF IX SS'),
    (LeftCtx:' '; Letters:'SIN';  RightCtx:' ';    Phonemes:'SS AY2 NN'),
    (LeftCtx:'^'; Letters:'SION'; RightCtx:'';     Phonemes:'SH UH NN'),
    (LeftCtx:'S';Letters:'S';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'.'; Letters:'S';    RightCtx:' ';    Phonemes:'ZZ'),
    (LeftCtx:'#:.E';Letters:'S';  RightCtx:' ';    Phonemes:'ZZ'),
    (LeftCtx:'#:^##';Letters:'S'; RightCtx:' ';    Phonemes:'ZZ'),
    (LeftCtx:'#:^#';Letters:'S';  RightCtx:' ';    Phonemes:'SS'),
    (LeftCtx:'U'; Letters:'S';    RightCtx:' ';    Phonemes:'SS'),
    (LeftCtx:' :#';Letters:'S';   RightCtx:' ';    Phonemes:'ZZ'),
    (LeftCtx:'##';Letters:'S';    RightCtx:' ';    Phonemes:'ZZ'),
    (LeftCtx:' '; Letters:'SCH';  RightCtx:'';     Phonemes:'SS KK'),
    (LeftCtx:'';  Letters:'SCH';  RightCtx:'';     Phonemes:'SS KK'),
    (LeftCtx:'';  Letters:'SCE';  RightCtx:'';     Phonemes:'SS'),
    (LeftCtx:'';  Letters:'SCI';  RightCtx:'';     Phonemes:'SS'),
    (LeftCtx:'#'; Letters:'SM';   RightCtx:'';     Phonemes:'ZZ UH MM'),
    (LeftCtx:'#'; Letters:'SN';   RightCtx:'''';   Phonemes:'ZZ UH NN'),
    (LeftCtx:'';  Letters:'STLE'; RightCtx:'';     Phonemes:'SS UL'),
    (LeftCtx:' '; Letters:'SONY'; RightCtx:'';     Phonemes:'SS OW3 NN IY'),
    (LeftCtx:'';  Letters:'STR';  RightCtx:'';     Phonemes:'SS TT RR'),
    (LeftCtx:'#'; Letters:'SURE'; RightCtx:'';     Phonemes:'ZH ER'),
    (LeftCtx:'U'; Letters:'S';    RightCtx:'E ';   Phonemes:'ZZ'),
    (LeftCtx:'';  Letters:'S';    RightCtx:'';     Phonemes:'SS'),

    // -------------------------------------------------------
    // T
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'T';    RightCtx:'. ';   Phonemes:'TT IY3'),
    (LeftCtx:' '; Letters:'THE';  RightCtx:'#';    Phonemes:'DH IY'),
    (LeftCtx:' '; Letters:'THE';  RightCtx:' ';    Phonemes:'DH AX'),
    (LeftCtx:' '; Letters:'TO';   RightCtx:' ';    Phonemes:'TT UW'),
    (LeftCtx:' '; Letters:'THAT'; RightCtx:'';     Phonemes:'DH AE TT'),
    (LeftCtx:' '; Letters:'THIS'; RightCtx:' ';    Phonemes:'DH IH SS'),
    (LeftCtx:' '; Letters:'THEY'; RightCtx:'';     Phonemes:'DH EY'),
    (LeftCtx:' '; Letters:'THERE';RightCtx:'';     Phonemes:'DH EH1 RR'),
    (LeftCtx:'';  Letters:'THER'; RightCtx:'';     Phonemes:'DH ER'),
    (LeftCtx:'';  Letters:'THEIR';RightCtx:'';     Phonemes:'DH EH1 RR'),
    (LeftCtx:' '; Letters:'THAN'; RightCtx:' ';    Phonemes:'DH AE NN'),
    (LeftCtx:' '; Letters:'THEM'; RightCtx:' ';    Phonemes:'DH EH MM'),
    (LeftCtx:' '; Letters:'THESE';RightCtx:' ';    Phonemes:'DH IY ZZ'),
    (LeftCtx:' '; Letters:'THEN'; RightCtx:'';     Phonemes:'DH EH NN'),
    (LeftCtx:'';  Letters:'THROUGH';RightCtx:'';   Phonemes:'TH RR UW'),
    (LeftCtx:'';  Letters:'THOSE';RightCtx:'';     Phonemes:'DH OH ZZ'),
    (LeftCtx:'';  Letters:'THOUGH';RightCtx:' ';   Phonemes:'DH OW'),
    (LeftCtx:'';  Letters:'TODAY';RightCtx:'';     Phonemes:'TT UW DD EY3'),
    (LeftCtx:'';  Letters:'TOMO'; RightCtx:'RROW'; Phonemes:'TT UH MM AA3'),
    (LeftCtx:'';  Letters:'TOGETHER';RightCtx:'';  Phonemes:'TT UW GG EH4 DH ER'),
    (LeftCtx:'';  Letters:'TO';   RightCtx:'TAL';  Phonemes:'TOW3'),
    (LeftCtx:' '; Letters:'THUS'; RightCtx:'';     Phonemes:'DH AH3 SS'),
    (LeftCtx:'';  Letters:'TIV';  RightCtx:'% ';   Phonemes:'TT IH VV'),
    (LeftCtx:'';  Letters:'THM';  RightCtx:' ';    Phonemes:'DH UH MM'),
    (LeftCtx:'';  Letters:'THM';  RightCtx:'%';    Phonemes:'DH UH MM'),
    (LeftCtx:'';  Letters:'THM';  RightCtx:'';     Phonemes:'DH MM'),
    (LeftCtx:'';  Letters:'TH';   RightCtx:'';     Phonemes:'TH'),
    (LeftCtx:'#'; Letters:'TED';  RightCtx:' ';    Phonemes:'TT IX DD'),
    (LeftCtx:'S'; Letters:'TI';   RightCtx:'#N';   Phonemes:'CH'),
    (LeftCtx:'';  Letters:'TI';   RightCtx:'O';    Phonemes:'SH'),
    (LeftCtx:'';  Letters:'TI';   RightCtx:'A';    Phonemes:'SH'),
    (LeftCtx:'';  Letters:'TIEN'; RightCtx:'';     Phonemes:'SH UH NN'),
    (LeftCtx:'';  Letters:'TUR';  RightCtx:'#';    Phonemes:'CH ER'),
    (LeftCtx:'';  Letters:'TU';   RightCtx:'A';    Phonemes:'CH UW'),
    (LeftCtx:' '; Letters:'TWO';  RightCtx:'';     Phonemes:'TT UW3'),
    (LeftCtx:'&'; Letters:'T';    RightCtx:'EN';   Phonemes:''),
    (LeftCtx:'F'; Letters:'T';    RightCtx:'EN';   Phonemes:''),
    (LeftCtx:'T';Letters:'T';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'TCH';  RightCtx:'';     Phonemes:'CH'),
    (LeftCtx:'';  Letters:'TION'; RightCtx:'';     Phonemes:'SH UN'),
    (LeftCtx:'';  Letters:'T';    RightCtx:'';     Phonemes:'TT'),

    // -------------------------------------------------------
    // U
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'U';    RightCtx:' ';    Phonemes:'YY UW3'),
    (LeftCtx:' '; Letters:'UNIM'; RightCtx:'';     Phonemes:'UH NN IH MM'),
    (LeftCtx:' '; Letters:'UNIN'; RightCtx:'';     Phonemes:'UH NN IH NN'),
    (LeftCtx:' '; Letters:'UN';   RightCtx:'I';    Phonemes:'YY UW NN'),
    (LeftCtx:'';  Letters:'UNDER';RightCtx:'';     Phonemes:'AH3 NN DD ER'),
    (LeftCtx:'';  Letters:'UNCLE';RightCtx:'';     Phonemes:'AH3 NX KK UL'),
    (LeftCtx:' '; Letters:'UN';   RightCtx:'^';    Phonemes:'AH1 NN'),
    (LeftCtx:' '; Letters:'UN';   RightCtx:'';     Phonemes:'UH NN'),
    (LeftCtx:' '; Letters:'UPON'; RightCtx:'';     Phonemes:'AX PP AA3 NN'),
    (LeftCtx:'@'; Letters:'UR';   RightCtx:'#';    Phonemes:'UH3 RR'),
    (LeftCtx:'';  Letters:'UR';   RightCtx:'#';    Phonemes:'YY UH3 RR'),
    (LeftCtx:'';  Letters:'UTION';RightCtx:'';     Phonemes:'YY UW3 SH UN'),
    (LeftCtx:'';  Letters:'UR';   RightCtx:'';     Phonemes:'ER'),
    (LeftCtx:'B'; Letters:'U';    RightCtx:'SH';   Phonemes:'UH4'),
    (LeftCtx:'P'; Letters:'U';    RightCtx:'SH';   Phonemes:'UH4'),
    (LeftCtx:'C'; Letters:'U';    RightCtx:'SH';   Phonemes:'UH4'),
    (LeftCtx:'';  Letters:'U';    RightCtx:'^ ';   Phonemes:'AH'),
    (LeftCtx:'';  Letters:'U';    RightCtx:'^^';   Phonemes:'AH4'),
    (LeftCtx:'';  Letters:'UY';   RightCtx:'';     Phonemes:'AY4'),
    (LeftCtx:'G'; Letters:'U';    RightCtx:'#';    Phonemes:''),
    (LeftCtx:'G'; Letters:'U';    RightCtx:'%';    Phonemes:''),
    (LeftCtx:'G'; Letters:'U';    RightCtx:'#';    Phonemes:'WW'),
    (LeftCtx:'#N';Letters:'U';    RightCtx:'';     Phonemes:'YY UW'),
    (LeftCtx:'@'; Letters:'U';    RightCtx:'SION'; Phonemes:'UW3'),
    (LeftCtx:'@'; Letters:'U';    RightCtx:'TION'; Phonemes:'UW3'),
    (LeftCtx:'';  Letters:'U';    RightCtx:'SION'; Phonemes:'YY UW3'),
    (LeftCtx:'';  Letters:'U';    RightCtx:'TION'; Phonemes:'YY UW3'),
    (LeftCtx:'@'; Letters:'U';    RightCtx:'';     Phonemes:'UW'),
    (LeftCtx:'U'; Letters:'U';    RightCtx:'';     Phonemes:''),
    (LeftCtx:' '; Letters:'USA';  RightCtx:' ';    Phonemes:'YY UW3 EH SS EY1'),
    (LeftCtx:'';  Letters:'U';    RightCtx:'^E ';  Phonemes:'YY UW'),
    (LeftCtx:'';  Letters:'U';    RightCtx:'';     Phonemes:'YY UW'),

    // -------------------------------------------------------
    // V
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'V';    RightCtx:'. ';   Phonemes:'VV IY4'),
    (LeftCtx:'';  Letters:'VIEW'; RightCtx:'';     Phonemes:'VV YY UW5'),
    (LeftCtx:'';  Letters:'VOCABULAR';RightCtx:''; Phonemes:'VV OH KK AE4 BB YY UL EH RR'),
    (LeftCtx:'V';Letters:'V';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'V';    RightCtx:'';     Phonemes:'VV'),

    // -------------------------------------------------------
    // W
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'W';    RightCtx:'. ';   Phonemes:'DD AH3 BB UL YY UW'),
    (LeftCtx:' '; Letters:'WERE'; RightCtx:'';     Phonemes:'WW ER'),
    (LeftCtx:'';  Letters:'WA';   RightCtx:'SH';   Phonemes:'WW AA4'),
    (LeftCtx:' '; Letters:'WAS';  RightCtx:' ';    Phonemes:'WW AH ZZ'),
    (LeftCtx:' '; Letters:'WE';   RightCtx:' ';    Phonemes:'WW IY'),
    (LeftCtx:' '; Letters:'WE''LL';RightCtx:' ';   Phonemes:'WW IY LL'),
    (LeftCtx:' '; Letters:'WE''D'; RightCtx:' ';   Phonemes:'WW IY DD'),
    (LeftCtx:' '; Letters:'WE''VE';RightCtx:' ';   Phonemes:'WW IY VV'),
    (LeftCtx:' '; Letters:'WITH'; RightCtx:' ';    Phonemes:'WW IH TH'),
    (LeftCtx:' '; Letters:'WITHOUT';RightCtx:'';   Phonemes:'WW IH TH AW3 TT'),
    (LeftCtx:' '; Letters:'WHY';  RightCtx:' ';    Phonemes:'WW AY'),
    (LeftCtx:'';  Letters:'WA';   RightCtx:'ST';   Phonemes:'WW EY4'),
    (LeftCtx:'';  Letters:'WA';   RightCtx:'S';    Phonemes:'WW AH'),
    (LeftCtx:'';  Letters:'WA';   RightCtx:'T';    Phonemes:'WW AA'),
    (LeftCtx:'';  Letters:'WHERE';RightCtx:'';     Phonemes:'WH EH RR'),
    (LeftCtx:'';  Letters:'WHAT'; RightCtx:'';     Phonemes:'WH AH TT'),
    (LeftCtx:'';  Letters:'WHOL'; RightCtx:'';     Phonemes:'HH OW4 LL'),
    (LeftCtx:'';  Letters:'WHO';  RightCtx:'';     Phonemes:'HH UW'),
    (LeftCtx:' '; Letters:'WILL'; RightCtx:'';     Phonemes:'WW IH LL'),
    (LeftCtx:'';  Letters:'WH';   RightCtx:'';     Phonemes:'WH'),
    (LeftCtx:'';  Letters:'WAR';  RightCtx:'#';    Phonemes:'WW EH4 RR'),
    (LeftCtx:'';  Letters:'WAR';  RightCtx:'';     Phonemes:'WW AO4 RR'),
    (LeftCtx:'';  Letters:'WOR';  RightCtx:'^';    Phonemes:'WW ER'),
    (LeftCtx:'';  Letters:'WR';   RightCtx:'';     Phonemes:'RR'),
    (LeftCtx:'';  Letters:'WOM';  RightCtx:'A';    Phonemes:'WW UH3 MM'),
    (LeftCtx:'';  Letters:'WOM';  RightCtx:'E';    Phonemes:'WW IH3 MM'),
    (LeftCtx:'';  Letters:'WEA';  RightCtx:'R';    Phonemes:'WW EH'),
    (LeftCtx:'';  Letters:'WAN';  RightCtx:'T';    Phonemes:'WW AA NN'),
    (LeftCtx:'ANS';Letters:'WER'; RightCtx:'';     Phonemes:'ER'),
    (LeftCtx:'';  Letters:'WINDOW';RightCtx:'';    Phonemes:'WW IH3 NN DD OW'),
    (LeftCtx:'W';Letters:'W';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'W';    RightCtx:'';     Phonemes:'WW'),

    // -------------------------------------------------------
    // X
    // -------------------------------------------------------
    (LeftCtx:'?'; Letters:'X';    RightCtx:'?';    Phonemes:'BB AY'),
    (LeftCtx:' '; Letters:'X';    RightCtx:'';     Phonemes:'BB AY'),
    (LeftCtx:' '; Letters:'X';    RightCtx:'. ';   Phonemes:'EH3 KK SS'),
    (LeftCtx:' '; Letters:'X';    RightCtx:'';     Phonemes:'ZZ'),
    (LeftCtx:'X'; Letters:'X';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'XC';   RightCtx:'+';    Phonemes:'KK SS'),
    (LeftCtx:'';  Letters:'X';    RightCtx:'';     Phonemes:'KK SS'),

    // -------------------------------------------------------
    // Y
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'Y';    RightCtx:' ';    Phonemes:'WW AY3'),
    (LeftCtx:'';  Letters:'YOUNG';RightCtx:'';     Phonemes:'YY AH NX'),
    (LeftCtx:' '; Letters:'YOUR'; RightCtx:'';     Phonemes:'YY OH RR'),
    (LeftCtx:' '; Letters:'YOU''RE';RightCtx:'';   Phonemes:'YY OH RR'),
    (LeftCtx:' '; Letters:'YOU';  RightCtx:'';     Phonemes:'YY UW'),
    (LeftCtx:' '; Letters:'YES';  RightCtx:'';     Phonemes:'YY EH2 SS'),
    (LeftCtx:' '; Letters:'Y';    RightCtx:'';     Phonemes:'YY'),
    (LeftCtx:'F'; Letters:'Y';    RightCtx:'';     Phonemes:'AY'),
    (LeftCtx:'PS';Letters:'YCH';  RightCtx:'';     Phonemes:'AY KK'),
    (LeftCtx:'#:^';Letters:'Y';   RightCtx:' ';    Phonemes:'IY'),
    (LeftCtx:'#:^';Letters:'Y';   RightCtx:'I';    Phonemes:'IY'),
    (LeftCtx:' :';Letters:'Y';    RightCtx:' ';    Phonemes:'AY'),
    (LeftCtx:' :';Letters:'Y';    RightCtx:'#';    Phonemes:'AY'),
    (LeftCtx:' :';Letters:'Y';    RightCtx:'^+:#'; Phonemes:'IH'),
    (LeftCtx:' :';Letters:'Y';    RightCtx:'^#';   Phonemes:'AY'),
    (LeftCtx:'Y';Letters:'Y';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'Y';    RightCtx:'';     Phonemes:'IH'),

    // -------------------------------------------------------
    // Z
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'Z';    RightCtx:'. ';   Phonemes:'ZZ IY3'),
    (LeftCtx:'Z';Letters:'Z';    RightCtx:'';     Phonemes:''),
    (LeftCtx:'';  Letters:'Z';    RightCtx:'';     Phonemes:'ZZ'),

    // -------------------------------------------------------
    // Digits
    // -------------------------------------------------------
    (LeftCtx:'';  Letters:'0';    RightCtx:'';     Phonemes:'ZZ IY4 RR OW'),
    (LeftCtx:' '; Letters:'1ST'; RightCtx:'';      Phonemes:'FF ER4 SS TT'),
    (LeftCtx:' '; Letters:'10TH';RightCtx:'';      Phonemes:'TT EH4 NN TH'),
    (LeftCtx:' '; Letters:'10';  RightCtx:' ';     Phonemes:'TT EH4 NN'),
    (LeftCtx:'';  Letters:'1';   RightCtx:'';      Phonemes:'WW AH4 NN'),
    (LeftCtx:' '; Letters:'2ND'; RightCtx:'';      Phonemes:'SS EH4 KK UH NN DD'),
    (LeftCtx:'';  Letters:'2';   RightCtx:'';      Phonemes:'TT UW4'),
    (LeftCtx:' '; Letters:'3RD'; RightCtx:'';      Phonemes:'TH ER4 DD'),
    (LeftCtx:'';  Letters:'3';   RightCtx:'';      Phonemes:'TH RR IY4'),
    (LeftCtx:'';  Letters:'4';   RightCtx:'';      Phonemes:'FF OH4 RR'),
    (LeftCtx:' '; Letters:'5TH'; RightCtx:'';      Phonemes:'FF IH4 FF TH'),
    (LeftCtx:'';  Letters:'5';   RightCtx:'';      Phonemes:'FF AY4 VV'),
    (LeftCtx:'';  Letters:'6';   RightCtx:'';      Phonemes:'SS IH4 KK SS'),
    (LeftCtx:'';  Letters:'7';   RightCtx:'';      Phonemes:'SS EH4 VV UH NN'),
    (LeftCtx:' '; Letters:'8TH'; RightCtx:'';      Phonemes:'EY4 TH'),
    (LeftCtx:'';  Letters:'8';   RightCtx:'';      Phonemes:'EY4 TT'),
    (LeftCtx:'';  Letters:'9';   RightCtx:'';      Phonemes:'NN AY4 NN'),

    // -------------------------------------------------------
    // Punctuation and special characters
    // -------------------------------------------------------
    (LeftCtx:'';  Letters:' ';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'...'; RightCtx:'';      Phonemes:'AE NN DD SS OW3 AA2 NN'),
    (LeftCtx:'';  Letters:'.';   RightCtx:'?';     Phonemes:'PP OY NN TT'),
    (LeftCtx:'';  Letters:'.';   RightCtx:' ';     Phonemes:'.'),
    (LeftCtx:'';  Letters:'.';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'!';   RightCtx:'';      Phonemes:'.'),
    (LeftCtx:'';  Letters:'"';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'##';  RightCtx:'';      Phonemes:'#'),
    (LeftCtx:'';  Letters:'#';   RightCtx:'';      Phonemes:'NN AH2 MM BB ER'),
    (LeftCtx:'C'; Letters:'''S'; RightCtx:'';      Phonemes:'SS'),
    (LeftCtx:'G'; Letters:'''S'; RightCtx:'';      Phonemes:'ZZ'),
    (LeftCtx:'&'; Letters:'''S'; RightCtx:'';      Phonemes:'IH ZZ'),
    (LeftCtx:'.'; Letters:'''S'; RightCtx:'';      Phonemes:'ZZ'),
    (LeftCtx:'#:&E';Letters:'''S';RightCtx:'';     Phonemes:'IH ZZ'),
    (LeftCtx:'#:.E';Letters:'''S';RightCtx:'';     Phonemes:'ZZ'),
    (LeftCtx:'#:^E';Letters:'''S';RightCtx:'';     Phonemes:'SS'),
    (LeftCtx:'#'; Letters:'''S'; RightCtx:'';      Phonemes:'ZZ'),
    (LeftCtx:'';  Letters:'''S'; RightCtx:'';      Phonemes:'SS'),
    (LeftCtx:'';  Letters:'''T'; RightCtx:'';      Phonemes:'TT'),
    (LeftCtx:'';  Letters:'''LL';RightCtx:'';      Phonemes:'LL'),
    (LeftCtx:'';  Letters:'''D'; RightCtx:'';      Phonemes:'DD'),
    (LeftCtx:'';  Letters:'''M'; RightCtx:'';      Phonemes:'MM'),
    (LeftCtx:'';  Letters:'$';   RightCtx:'';      Phonemes:'DD AA2 LL ER'),
    (LeftCtx:'';  Letters:'%';   RightCtx:'';      Phonemes:'PP ER SS EH2 NN TT'),
    (LeftCtx:'';  Letters:'&';   RightCtx:'';      Phonemes:'AE NN DD'),
    (LeftCtx:'';  Letters:'''';  RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'*';   RightCtx:'';      Phonemes:'AE3 SS TT ER IH SS KK'),
    (LeftCtx:'';  Letters:'+';   RightCtx:'';      Phonemes:'PP LL AH3 SS'),
    (LeftCtx:'';  Letters:',';   RightCtx:'';      Phonemes:','),
    (LeftCtx:' '; Letters:'-';   RightCtx:' ';     Phonemes:'-'),
    (LeftCtx:'';  Letters:'-';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'/';   RightCtx:'';      Phonemes:'SS LL AE2 SH'),
    (LeftCtx:'';  Letters:':';   RightCtx:'';      Phonemes:'.'),
    (LeftCtx:'';  Letters:';';   RightCtx:'';      Phonemes:'.'),
    (LeftCtx:'';  Letters:'<';   RightCtx:'';      Phonemes:'LL EH3 SS DH AE NN'),
    (LeftCtx:'';  Letters:'=';   RightCtx:'';      Phonemes:'IY3 KK WW UL ZZ'),
    (LeftCtx:'';  Letters:'>';   RightCtx:'';      Phonemes:'GG RR EY3 TT ER DH AE NN'),
    (LeftCtx:'';  Letters:'?';   RightCtx:'';      Phonemes:'.'),
    (LeftCtx:'';  Letters:'@';   RightCtx:'';      Phonemes:'AE2 TT'),
    (LeftCtx:'';  Letters:'(';   RightCtx:'';      Phonemes:','),
    (LeftCtx:'';  Letters:')';   RightCtx:'';      Phonemes:','),
    (LeftCtx:'';  Letters:'^';   RightCtx:'';      Phonemes:'KK AE2 RR IH TT'),
    (LeftCtx:'';  Letters:'~';   RightCtx:'';      Phonemes:'TT IH3 LL DD AH'),
    (LeftCtx:'';  Letters:'\';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'[';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'{';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'}';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'|';   RightCtx:'';      Phonemes:'OH RR'),
    (LeftCtx:'';  Letters:'_';   RightCtx:'';      Phonemes:''),
    (LeftCtx:'';  Letters:'`';   RightCtx:'';      Phonemes:''),

    // sentinel
    (LeftCtx:''; Letters:''; RightCtx:''; Phonemes:''));

// ---------------------------------------------------------------------------
// Whole-word exception table
// Irregular words whose LTS rules would get wrong
// ---------------------------------------------------------------------------

Const
  WordExceptionCount = 16;

  WordExceptions: Array[0..WordExceptionCount-1, 0..1] of aString = (
    // SpecBAS keywords - the LTS rules would mangle these
    ('SPECBAS',  'SS PP EH3 KK BB AE SS'),
    ('GOTO',     'GG OW3 TT OW'),
    ('GOSUB',    'GG OW3 SS AH BB'),
    ('PRINTLN',  'PP RR IH3 NN TT LL AY NN'),
    ('AMIGA',    'AH MM IY3 GG AH'),
    // Contractions the rules might not catch in all contexts
    ('WON''T',   'WW OW4 NN TT'),
    ('DON''T',   'DD OW4 NN TT'),
    ('CAN''T',   'KK AE4 NN TT'),
    ('DOESN''T', 'DD AH ZZ IH NN TT'),
    ('ISN''T',   'IH ZZ IH NN TT'),
    ('WASN''T',  'WW AH ZZ IH NN TT'),
    ('WEREN''T', 'WW ER IH NN TT'),
    ('COULDN''T','KK UH DD IH NN TT'),
    // Words where LTS rules produce the wrong vowel
    // ZERO: ER-before-vowel rule fires giving ZZ EH1 RR; correct is ZZ IY4 RR OW
    ('ZERO',     'ZZ IY4 RR OW'),
    // WEATHER: EA-default fires giving WW IY; TH is voiced (/ð/), vowel is short EH
    ('WEATHER',  'WW EH4 DH ER'),
    // SHE: no vowel precedes E so magic-E rule cannot fire; E must map to IY
    ('SHE',      'SH IY'));

// ---------------------------------------------------------------------------
// Context matching helpers
// ---------------------------------------------------------------------------

Function IsVowelChar(c: aChar): Boolean;
Begin
  Result := SP_Util.Pos(c, 'AEIOU') > 0;
End;

Function IsFrontVowel(c: aChar): Boolean;
Begin
  Result := SP_Util.Pos(c, 'EIY') > 0;
End;

Function IsConsonantChar(c: aChar): Boolean;
Begin
  Result := IsAlpha(c) And Not IsVowelChar(c);
End;

// Match a context pattern against a substring of s at position p.
// Direction: +1 = rightward (right context), -1 = leftward (left context).
// Returns true if pattern matches.

Function MatchContext(Const Pattern, s: aString;
                      Start, Dir: Integer): Boolean;
Var
  pi, si: Integer;
  c:      aChar;
Begin
  Result := True;
  If Pattern = '' Then Exit;  // empty pattern always matches

  pi := 1;
  si := Start;

  If Dir = -1 Then Begin
    // Left context: match pattern right-to-left against s left-of-start
    pi := Length(Pattern);
    si := Start;
  End;

  While (pi >= 1) And (pi <= Length(Pattern)) Do Begin
    c := Pattern[pi];
    // Boundary
    If (si < 1) Or (si > Length(s)) Then Begin
      If c = ' ' Then Begin
        Inc(pi, Dir); Continue;
      End Else Begin
        Result := False; Exit;
      End;
    End;

    Case c Of
      ' ': // word boundary
        If (s[si] = ' ') Then Inc(si, Dir)
        Else Begin Result := False; Exit; End;

      '#': // one or more vowels
        Begin
          If Not IsVowelChar(s[si]) Then Begin Result := False; Exit; End;
          While (si >= 1) And (si <= Length(s)) And IsVowelChar(s[si]) Do
            Inc(si, Dir);
        End;

      ':': // zero or more consonants
        Begin
          While (si >= 1) And (si <= Length(s)) And IsConsonantChar(s[si]) Do
            Inc(si, Dir);
        End;

      '^': // exactly one consonant
        Begin
          If Not IsConsonantChar(s[si]) Then Begin Result := False; Exit; End;
          Inc(si, Dir);
        End;

      '+': // front vowel
        Begin
          If Not IsFrontVowel(s[si]) Then Begin Result := False; Exit; End;
          Inc(si, Dir);
        End;

      '@': // voiced consonant
        Begin
          If SP_Util.Pos(s[si], 'BDGJLMNRVWZ') = 0 Then
            Begin Result := False; Exit; End;
          Inc(si, Dir);
        End;

      '&': // sibilant consonant
        Begin
          If SP_Util.Pos(s[si], 'SCGZXJ') = 0 Then
            Begin Result := False; Exit; End;
          Inc(si, Dir);
        End;

      '!': // non-alphabetic character
        Begin
          If IsAlpha(s[si]) Then
            Begin Result := False; Exit; End;
          Inc(si, Dir);
        End;

      '%': // suffix - matches ER ED ING E EST LY
        Begin
          // Try each suffix in turn, right context only
          If Dir = 1 Then Begin
            If (si + 1 <= Length(s)) And
               ((Copy(s, si, 2) = 'ER') Or
                (Copy(s, si, 2) = 'ED') Or
                (Copy(s, si, 2) = 'LY')) Then Begin
              Inc(si, 2);
            End Else If (si + 2 <= Length(s)) And
               ((Copy(s, si, 3) = 'ING') Or
                (Copy(s, si, 3) = 'EST')) Then Begin
              Inc(si, 3);
            End Else If (si <= Length(s)) And
               (s[si] = 'E') And
               ((si + 1 > Length(s)) Or
                Not IsAlpha(s[si + 1])) Then Begin
              Inc(si, 1);
            End Else Begin
              Result := False; Exit;
            End;
          End Else Begin
            // Left context: check what came before
            If (si - 1 >= 1) And
               ((Copy(s, si - 1, 2) = 'ER') Or
                (Copy(s, si - 1, 2) = 'ED') Or
                (Copy(s, si - 1, 2) = 'LY')) Then Begin
              Dec(si, 2);
            End Else If (si - 2 >= 1) And
               ((Copy(s, si - 2, 3) = 'ING') Or
                (Copy(s, si - 2, 3) = 'EST')) Then Begin
              Dec(si, 3);
            End Else If (si >= 1) And (s[si] = 'E') Then Begin
              Dec(si, 1);
            End Else Begin
              Result := False; Exit;
            End;
          End;
        End;

    Else
      // Literal character match
      If s[si] <> c Then Begin Result := False; Exit; End;
      Inc(si, Dir);
    End;
    Inc(pi, Dir);
  End;
End;

// ---------------------------------------------------------------------------
// LTS rule engine
// ---------------------------------------------------------------------------

Function ApplyLTSRules(Const s: aString): aString;
Var
  // Pad with spaces for boundary detection
  Padded:    aString;
  i, j:      Integer;
  Matched:   Boolean;
  Rule:      TLTSRule;
  LL:        Integer;   // left/right context anchors in Padded
  Word:      aString;
  WordStart: Integer;

  // Emit phonemes to result, adding space separator
  Procedure Emit(Const p: aString);
  Var
    Clean: aString;
    k:     Integer;
  Begin
    If p = '' Then Exit;
    // Strip /H weak-form markers from Amiga rule output.
    // Replace leading / on HH tokens with reduced aspiration flag.
    // For now we simply remove the / and emit HH at normal level.
    Clean := '';
    k := 1;
    While k <= Length(p) Do Begin
      If (p[k] = '/') And (k < Length(p)) And
         (p[k+1] = 'H') Then Begin
        // /H ? HH (weak form: synthesiser handles as normal HH for now)
        Inc(k); // skip the slash, keep H
      End Else Begin
        Clean := Clean + p[k];
        Inc(k);
      End;
    End;
    If Clean = '' Then Exit;
    If Result <> '' Then Result := Result + ' ';
    Result := Result + Clean;
  End;

Begin
  Result := '';
  Padded := ' ' + s + ' ';  // pad for boundary matching
  i := 2;                    // skip leading space

  While i <= Length(Padded) - 1 Do Begin  // skip trailing space

    // Punctuation pause tokens
    If Padded[i] = '.' Then Begin
      Emit('PA3'); Inc(i); Continue;
    End;
    If Padded[i] = ',' Then Begin
      Emit('PA2'); Inc(i); Continue;
    End;
    If Padded[i] = '?' Then Begin
      Emit('PA4'); Inc(i); Continue;  // PA4 = question boundary (rising tone)
    End;

    // Emit PA1 at each word boundary so AssignStressMarks can identify
    // per-word phoneme groups. These markers are stripped from the final
    // output by SP_NarratorTranslate after stress assignment; they are
    // not intended as audible pauses. PA2 and PA3 (comma and sentence
    // boundaries) are retained as audible pauses.
    If Padded[i] = ' ' Then Begin
      If (i > 2) And (i < Length(Padded) - 1) Then
        Emit('PA1');
      Inc(i);
      Continue;
    End;

    // Check whole-word exception table first
    // Find word boundaries
    If IsAlpha(Padded[i]) And (Padded[i-1] = ' ') Then Begin
      WordStart := i;
      j := i;
      While (j <= Length(Padded)) And IsAlpha(Padded[j]) Do Inc(j);
      Word := Copy(Padded, WordStart, j - WordStart);
      Matched := False;
      For j := 0 To WordExceptionCount - 1 Do
        If Word = WordExceptions[j][0] Then Begin
          Emit(WordExceptions[j][1]);
          Inc(i, Length(Word));
          Matched := True;
          Break;
        End;
      If Matched Then Continue;
    End;

    // Try LTS rules
    Matched := False;
    For j := 0 To LTSRuleCount - 2 Do Begin  // -2 to skip sentinel
      Rule := LTSRules[j];
      If Rule.Letters = '' Then Continue;

      // Match Letters at position i
      LL := Length(Rule.Letters);
      If i + LL - 1 > Length(Padded) Then Continue;
      If Copy(Padded, i, LL) <> Rule.Letters Then Continue;

      // Match left context (position i-1, going left)
      If Not MatchContext(Rule.LeftCtx, Padded, i - 1, -1) Then Continue;

      // Match right context (position i+LL, going right)
      If Not MatchContext(Rule.RightCtx, Padded, i + LL, 1) Then Continue;

      // Rule matched
      Emit(Rule.Phonemes);
      Inc(i, LL);
      Matched := True;
      Break;
    End;

    // No rule matched - emit nothing and advance one character
    If Not Matched Then Inc(i);

  End;
End;

// True if Token names a vowel phoneme (eligible for a stress digit)
Function IsVowelPhoneme(Const Token: aString): Boolean;
Var
  tok: aString;
Begin
  tok := Copy(Token, 1, 2);
  Result := (Tok = 'IY') Or (Tok = 'IH') Or (Tok = 'EH') Or
            (Tok = 'AE') Or (Tok = 'AA') Or (Tok = 'AH') Or
            (Tok = 'AO') Or (Tok = 'OW') Or (Tok = 'UH') Or
            (Tok = 'UW') Or (Tok = 'ER') Or (Tok = 'AX') Or
            (Tok = 'AY') Or (Tok = 'AW') Or (Tok = 'OY') Or
            (Tok = 'EY') Or (Tok = 'IX') Or (Tok = 'OH');
End;

// True if Token is a schwa-type reduced vowel (always stress 0)
Function IsSchwaPhoneme(Const Token: aString): Boolean;
Begin
  Result := (Token = 'AX') Or (Token = 'IX');
End;

// True if a phoneme token is a PAn pause
Function IsPausePhoneme(Const Token: aString): Boolean;
Begin
  Result := (Length(Token) >= 2) And (Token[1] = 'P') And (Token[2] = 'A');
End;

// Post-process a raw phoneme string, appending a stress digit to every vowel.
// Operates word-by-word; word boundaries are the PA pause tokens emitted by
// ApplyLTSRules.
Function AssignStressMarks(Const Phonemes: aString): aString;
// Replicates translator.library FUN_0021f59e exactly:
// - If a word already has any stress digit in its phoneme output, leave it alone
// - If no digit found, insert '4' after the first non-schwa vowel
// - AX and IX (schwas) never receive a stress digit
// - Function words: the LTS rules already output reduced forms for the
//   most common ones; remaining function words get 4 like everything else,
//   which is correct (they are weakly stressed, not silent)
Var
  Tokens:       Array of aString;
  TokCount:     Integer;
  i, j:        Integer;
  p, q:        Integer;
  Tok:         aString;
  WordStart:   Integer;
  WordEnd:     Integer;
  HasDigit:    Boolean;
  FirstVowel:  Integer;  // index into Tokens of first non-schwa vowel in word

  // Vowel set that the Amiga scans for stress insertion �
  // matches the table at $21f750 in translator.library exactly.
  // AX and IX are deliberately excluded.
  Function IsAmigaVowel(Const t: aString): Boolean;
  Var base: aString;
  Begin
    base := Copy(t, 1, 2);
    Result := (base = 'IH') Or (base = 'EH') Or (base = 'AA') Or
              (base = 'AE') Or (base = 'IY') Or (base = 'AO') Or
              (base = 'AH') Or (base = 'ER') Or (base = 'OH') Or
              (base = 'EY') Or (base = 'AY') Or (base = 'OY') Or
              (base = 'AW') Or (base = 'OW') Or (base = 'UW');
  End;

  Function TokenHasDigit(Const t: aString): Boolean;
  Var k: Integer;
  Begin
    Result := False;
    For k := 1 To Length(t) Do
      If t[k] In ['0'..'9'] Then Begin
        Result := True; Exit;
      End;
  End;

Begin
  Result := '';
  If Phonemes = '' Then Exit;

  // ---- Tokenise ----
  SetLength(Tokens, 512);
  TokCount := 0;
  p := 1;
  While p <= Length(Phonemes) Do Begin
    While (p <= Length(Phonemes)) And (Phonemes[p] = ' ') Do Inc(p);
    If p > Length(Phonemes) Then Break;
    q := p;
    While (q <= Length(Phonemes)) And (Phonemes[q] <> ' ') Do Inc(q);
    If TokCount < Length(Tokens) Then Begin
      Tokens[TokCount] := Copy(Phonemes, p, q - p);
      Inc(TokCount);
    End;
    p := q;
  End;

  // ---- Process word groups ----
  i := 0;
  While i < TokCount Do Begin

    If IsPausePhoneme(Tokens[i]) Then Begin
      Inc(i); Continue;
    End;

    // Find end of this word group
    WordStart := i;
    WordEnd   := i;
    While (WordEnd < TokCount) And Not IsPausePhoneme(Tokens[WordEnd]) Do
      Inc(WordEnd);
    // Tokens[WordStart .. WordEnd-1] = one word

    // Step 1: does any token in this word already have a digit?
    HasDigit   := False;
    FirstVowel := -1;
    For j := WordStart To WordEnd - 1 Do Begin
      If TokenHasDigit(Tokens[j]) Then Begin
        HasDigit := True;
        Break;
      End;
      // Track first non-schwa vowel for possible insertion
      If (FirstVowel < 0) And IsAmigaVowel(Tokens[j]) Then
        FirstVowel := j;
    End;

    // Step 2: if no digit and a vowel was found, insert default stress 4
    If Not HasDigit And (FirstVowel >= 0) Then
      Tokens[FirstVowel] := Tokens[FirstVowel] + '4';

    // Step 3: ensure AX/IX always have stress 0 regardless of rules
    For j := WordStart To WordEnd - 1 Do Begin
      Tok := Tokens[j];
      If (Copy(Tok, 1, 2) = 'AX') Or (Copy(Tok, 1, 2) = 'IX') Then Begin
        // Strip any digit that rules may have added and force 0
        While (Length(Tok) > 2) And (Tok[Length(Tok)] In ['0'..'9']) Do
          Tok := Copy(Tok, 1, Length(Tok) - 1);
        Tokens[j] := Tok + '0';
      End;
    End;

    i := WordEnd;
  End;

  // ---- Reassemble ----
  For i := 0 To TokCount - 1 Do Begin
    If Result <> '' Then Result := Result + ' ';
    Result := Result + Tokens[i];
  End;
End;

// ---------------------------------------------------------------------------
// SP_IsAmigaSpeech
// Returns True if s is identifiably an Amiga Narrator.device phoneme string.
// Returns False when ambiguous or when s is in SpecBAS allophone format.
//
// Four unambiguous Amiga markers are tested:
//
//  1. /H or /C anywhere in the string.
//  2. A stress digit 4-9 that is not part of a SpecBAS PA4 or PA5 token.
//     (Digits 6-9 never appear in SpecBAS output at all;
//      digits 4-5 appear only in PA4/PA5, identifiable by 'PA' immediately
//      before the digit.)
//  3. A space-delimited token of length 1 that is a valid single-char alias
//     (P B T D K G M N F V S Z R L W Y H C J Q).
//  4. A space-delimited token of length >= 4, indicating a concatenated
//     allophone group such as "RAE4BIHT" which SpecBAS never produces.
//
// Strings that trigger none of these markers -- typically bare two-char
// allophone sequences with no stress digits -- are valid in both formats
// and parse identically either way, so False (SpecBAS) is the safe default.
// ---------------------------------------------------------------------------

Function SP_IsAmigaSpeech(Const s: aString): Boolean;
Const
  SingleCharAliases = 'PBTDKGMNFVSZRLWYHCJQ';
Var
  Upper:             aString;
  i, WordStart, WLen: Integer;
  c:                 aChar;
Begin
  Result := False;
  If s = '' Then Exit;

  Upper := SP_Util.Upper(SP_Trim(aString(s)));

  // ---- Pass 1: character-level markers (slash tokens, high stress digits) ----
  For i := 1 To Length(Upper) Do Begin
    c := Upper[i];

    // Marker 1: /H or /C
    If c = '/' Then
      If (i < Length(Upper)) And ((Upper[i+1] = 'H') Or (Upper[i+1] = 'C')) Then Begin
        Result := True; Exit;
      End;

    // Marker 2: Amiga stress digits 6-9 never appear in SpecBAS output.
    // SpecBAS uses digits 1-5 only (level 4 = default neutral, inserted by
    // AssignStressMarks).  Digits 6-9 are Amiga-only high-stress values.
    If (c >= '6') And (c <= '9') Then Begin
      Result := True; Exit;
    End;
  End;

  // ---- Pass 2: word-level markers (token length) ----
  i := 1;
  While i <= Length(Upper) Do Begin

    While (i <= Length(Upper)) And (Upper[i] = ' ') Do Inc(i);
    If i > Length(Upper) Then Break;

    WordStart := i;
    While (i <= Length(Upper)) And (Upper[i] <> ' ') Do Inc(i);
    WLen := i - WordStart;

    // Marker 4: concatenated chunk -- SpecBAS tokens are at most 3 chars
    If WLen >= 4 Then Begin Result := True; Exit; End;

    // Marker 3: single-letter consonant alias
    If (WLen = 1) And (SP_Util.Pos(Upper[WordStart], SingleCharAliases) > 0) Then Begin
      Result := True; Exit;
    End;

  End;
End;

// ---------------------------------------------------------------------------
// SP_NarratorFromAmiga
// Converts an Amiga Narrator.device phoneme string to SpecBAS allophone format.
//
// Amiga format:
//   Allophones are concatenated without spaces within a word group; word
//   groups are separated by spaces, which produce no pause in the output.
//   A stress digit (0-9) may follow any vowel allophone directly.
//   /H maps to HH, /C maps to KH.
//   Single-letter consonant aliases are accepted (P=PP, B=BB, T=TT, etc.).
//   The string may optionally be enclosed in leading/trailing / delimiters.
//
// Stress mapping (Amiga 0-9 -> SpecBAS 0-2):
//   no digit       -> 1  (normal)
//   digit 0, 1-3   -> 0  (unstressed / light)
//   digit 4-9      -> 2  (primary / heavy)
// ---------------------------------------------------------------------------

Function SP_NarratorFromAmiga(Const AmigaStr: aString): aString;
Const
  NumTwoChar = 49;
  TwoChar: Array[0..NumTwoChar-1] of String[2] = (
    'IY','IH','EH','AE','AA','AH','AO','OW','UH','UW',
    'ER','AX','IX','OH',
    'AY','AW','OY','EY',
    'WW','RR','LL','YY','WH','RX','LX','DX',
    'MM','NN','NX',
    'FF','TH','SS','SH','HH','KH','VV','DH','ZZ','ZH',
    'CH','JH',
    'PP','TT','KK','BB','DD','GG',
    'QQ','QX'
  );
  NumVowels = 18;
  VowelSet: Array[0..NumVowels-1] of String[2] = (
    'IY','IH','EH','AE','AA','AH','AO','OW','UH','UW',
    'ER','AX','IX','OH',
    'AY','AW','OY','EY'
  );
Var
  s:       aString;
  i, k:    Integer;
  Token:   aString;
  Stress:  Integer;
  IsVowel: Boolean;
  Found:   Boolean;
Begin
  Result := '';
  s := SP_Util.Upper(SP_Trim(aString(AmigaStr)));
  If s = '' Then Exit;

  i := 1;
  While i <= Length(s) Do Begin

    // Word-boundary space: skip, no pause emitted.
    If s[i] = ' ' Then Begin
      Inc(i);
      Continue;
    End;

    Token  := '';
    Stress := -1;   // -1 = no digit seen

    // /H and /C slash-prefixed tokens
    If s[i] = '/' Then Begin
      If i + 1 <= Length(s) Then Begin
        If      s[i+1] = 'H' Then Begin Token := 'HH'; Inc(i, 2); End
        Else If s[i+1] = 'C' Then Begin Token := 'KH'; Inc(i, 2); End
        Else                       Inc(i);   // unrecognised /x -- skip slash
      End Else
        Inc(i);

    End Else Begin

      // Try two-character allophone name first
      Found := False;
      If i + 1 <= Length(s) Then Begin
        For k := 0 To NumTwoChar - 1 Do
          If (s[i] = TwoChar[k][1]) And (s[i+1] = TwoChar[k][2]) Then Begin
            Token := aString(TwoChar[k]);
            Inc(i, 2);
            Found := True;
            Break;
          End;
      End;

      // Single-character consonant alias (only reached if two-char did not match)
      If Not Found Then Begin
        Case s[i] Of
          'P': Token := 'PP';  'B': Token := 'BB';
          'T': Token := 'TT';  'D': Token := 'DD';
          'K': Token := 'KK';  'G': Token := 'GG';
          'M': Token := 'MM';  'N': Token := 'NN';
          'F': Token := 'FF';  'V': Token := 'VV';
          'S': Token := 'SS';  'Z': Token := 'ZZ';
          'R': Token := 'RR';  'L': Token := 'LL';
          'W': Token := 'WW';  'Y': Token := 'YY';
          'H': Token := 'HH';  'C': Token := 'KH';
          'J': Token := 'JH';  'Q': Token := 'QQ';
          // Vowel single-char shortcuts used in concatenated Amiga strings
          'I': Token := 'IH';  // "DHIS" = DH+IH+SS
          'U': Token := 'UH';  // "KUMPYUW3TER" = KK+UH+MM...
          'E': Token := 'EH';
          'A': Token := 'AH';
          'O': Token := 'OH';
        End;
        Inc(i);
      End;

    End;

    If Token = '' Then Continue;   // unrecognised character -- skip

    // Consume an optional trailing stress digit
    If (i <= Length(s)) And (s[i] >= '0') And (s[i] <= '9') Then Begin
      Stress := Ord(s[i]) - Ord('0');
      Inc(i);
    End;

    // Determine whether this token is a vowel phoneme
    IsVowel := False;
    For k := 0 To NumVowels - 1 Do
      If Token = aString(VowelSet[k]) Then Begin
        IsVowel := True;
        Break;
      End;

    // Append to output
    If Result <> '' Then Result := Result + ' ';
    If IsVowel Then Begin
      // AX and IX are always schwa � stress 0 regardless of digit
      If (Token = 'AX') Or (Token = 'IX') Then
        Result := Result + Token + '0'
      Else If Stress < 0 Then
        // No digit in Amiga string = default neutral = our level 4
        Result := Result + Token + '4'
      Else If Stress = 0 Then
        // Amiga digit 0 = explicitly unstressed = our level 0
        Result := Result + Token + '0'
      Else If Stress <= 5 Then
        // Amiga digits 1-5 map directly to our levels 1-5
        Result := Result + Token + aChar(Ord('0') + Stress)
      Else
        // Amiga digits 6-9 = treat as neutral level 4
        Result := Result + Token + '4'
    End Else
      Result := Result + Token;

  End;
End;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

Function TheAllophony(Const Phonemes: aString): aString;
// Replace "DH AX PA1 <vowel>" with "DH IY PA1 <vowel>" � the allophonic
// variation of "the" before vowel-initial words, matching the Amiga's DHIY.
Var
  Tokens:   Array of aString;
  TokCount: Integer;
  p, q, i:  Integer;
  IsVowel:  Boolean;
  Base:     aString;
Begin
  // Tokenise
  SetLength(Tokens, 512);
  TokCount := 0;
  p := 1;
  While p <= Length(Phonemes) Do Begin
    While (p <= Length(Phonemes)) And (Phonemes[p] = ' ') Do Inc(p);
    If p > Length(Phonemes) Then Break;
    q := p;
    While (q <= Length(Phonemes)) And (Phonemes[q] <> ' ') Do Inc(q);
    If TokCount < Length(Tokens) Then Begin
      Tokens[TokCount] := Copy(Phonemes, p, q - p);
      Inc(TokCount);
    End;
    p := q;
  End;

  // Scan for DH AX PA1 <vowel>
  For i := 0 To TokCount - 4 Do Begin
    If (Tokens[i] = 'DH') And
       ((Tokens[i+1] = 'AX') Or (Tokens[i+1] = 'AX0')) And
       (Tokens[i+2] = 'PA1') Then Begin
      // Check if next real token is a vowel phoneme
      Base := Copy(Tokens[i+3], 1, 2);
      IsVowel := (Base='IH') Or (Base='EH') Or (Base='AA') Or (Base='AE') Or
                 (Base='IY') Or (Base='AO') Or (Base='AH') Or (Base='ER') Or
                 (Base='OH') Or (Base='EY') Or (Base='AY') Or (Base='OY') Or
                 (Base='AW') Or (Base='OW') Or (Base='UW') Or (Base='AX') Or
                 (Base='IX') Or (Base='UH');
      If IsVowel Then
        Tokens[i+1] := 'IY4';  // fully specify to survive AssignStressMarks
    End;
  End;

  // Reassemble
  Result := '';
  For i := 0 To TokCount - 1 Do Begin
    If Result <> '' Then Result := Result + ' ';
    Result := Result + Tokens[i];
  End;
End;

Function IntervenocelicFlap(Const Phonemes: aString): aString;
// Replace TT with DX (alveolar flap) when it falls between two vowel phonemes.
// Covers "butter", "water", "better", "city", "pretty" etc.
// PA tokens between the vowel and the TT are transparent to the check �
// this handles cases where word boundaries fall between vowel and consonant.
Var
  Tokens:         Array of aString;
  TokCount:       Integer;
  p, q, i, j:     Integer;
  PrevIsVowel:    Boolean;
  NextIsVowel:    Boolean;
  b:              aString;

  Function IsVowelTok(Const t: aString): Boolean;
  Begin
    b := Copy(t, 1, 2);
    Result := (b='IH') Or (b='EH') Or (b='AA') Or (b='AE') Or
              (b='IY') Or (b='AO') Or (b='AH') Or (b='ER') Or
              (b='OH') Or (b='EY') Or (b='AY') Or (b='OY') Or
              (b='AW') Or (b='OW') Or (b='UW') Or (b='AX') Or
              (b='IX') Or (b='UH');
  End;

Begin
  // ---- Tokenise ----
  SetLength(Tokens, 512);
  TokCount := 0;
  p := 1;
  While p <= Length(Phonemes) Do Begin
    While (p <= Length(Phonemes)) And (Phonemes[p] = ' ') Do Inc(p);
    If p > Length(Phonemes) Then Break;
    q := p;
    While (q <= Length(Phonemes)) And (Phonemes[q] <> ' ') Do Inc(q);
    If TokCount < Length(Tokens) Then Begin
      Tokens[TokCount] := Copy(Phonemes, p, q - p);
      Inc(TokCount);
    End;
    p := q;
  End;

  // ---- Scan for vowel [PA*]* TT [PA*]* vowel ----
  For i := 1 To TokCount - 2 Do Begin
    If Copy(Tokens[i], 1, 2) <> 'TT' Then Continue;

    // Search backward past any pause tokens for a vowel
    PrevIsVowel := False;
    j := i - 1;
    While (j >= 0) And IsPausePhoneme(Tokens[j]) Do Dec(j);
    If j >= 0 Then PrevIsVowel := IsVowelTok(Tokens[j]);

    // Search forward past any pause tokens for a vowel
    NextIsVowel := False;
    j := i + 1;
    While (j < TokCount) And IsPausePhoneme(Tokens[j]) Do Inc(j);
    If j < TokCount Then NextIsVowel := IsVowelTok(Tokens[j]);

    If PrevIsVowel And NextIsVowel Then Begin
      // Preserve any stress digit that may be on the TT token (unusual but safe)
      If (Length(Tokens[i]) > 2) And
         (Tokens[i][Length(Tokens[i])] In ['0'..'9']) Then
        Tokens[i] := aString('DX' + Tokens[i][Length(Tokens[i])])
      Else
        Tokens[i] := 'DX';
    End;
  End;

  // ---- Reassemble ----
  Result := '';
  For i := 0 To TokCount - 1 Do Begin
    If Result <> '' Then Result := Result + ' ';
    Result := Result + Tokens[i];
  End;
End;

Function SP_NarratorTranslate(Const Text: aString): aString;
Var
  Normalised: aString;
  Stressed:   aString;
Begin
  Normalised := NormaliseText(Text);
  Stressed   := AssignStressMarks(TheAllophony(ApplyLTSRules(Normalised)));
  Stressed   := IntervenocelicFlap(Stressed);
  Result := aString(StringReplace(String(Stressed), ' PA1', '', [rfReplaceAll]));
  If Copy(Result, 1, 3) = 'PA1' Then
    If Length(Result) = 3 Then Result := ''
    Else Result := Copy(Result, 5, Length(Result));
End;

end.
