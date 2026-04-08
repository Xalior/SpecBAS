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
      // Expand digit run to words
      If (Result <> '') And (Result[Length(Result)] <> ' ') Then
        Result := Result + ' ';
      Result := Result + ExpandDigits(s, i);
      Result := Result + ' ';
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

  LTSRuleCount = 200;

  LTSRules: Array[0..LTSRuleCount-1] of TLTSRule = (

    // -------------------------------------------------------
    // A
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'A';   RightCtx:' ';   Phonemes:'AX'),     // "A" (standalone)
    (LeftCtx:'F'; Letters:'A';   RightCtx:'TH';  Phonemes:'AA'),     // "Father"
    (LeftCtx:'';  Letters:'A';   RightCtx:'W#';  Phonemes:'AX'),     // "Awake", "Award" (A before W + vowel is Schwa)
    (LeftCtx:'';  Letters:'A';   RightCtx:'TION';Phonemes:'EY'),     // "Nation", "Station"
    (LeftCtx:'';  Letters:'A';   RightCtx:'B';   Phonemes:'AX'),     // "About"
    (LeftCtx:'^'; Letters:'A';   RightCtx:'^#';  Phonemes:'EY'),     // "Bacon", "Paper" (A before 1 consonant + vowel is EY)
    (LeftCtx:' '; Letters:'ARE'; RightCtx:' ';   Phonemes:'AA RR'),  // "Are"
    (LeftCtx:'';  Letters:'AR';  RightCtx:'O';   Phonemes:'AX RR'),  // "Around"
    (LeftCtx:'';  Letters:'AR';  RightCtx:'#';   Phonemes:'EH RR'),  // "Parent"
    (LeftCtx:'^'; Letters:'AS';  RightCtx:'#';   Phonemes:'EY SS'),  // "Basin"

    // MULTI-LETTER COMBOS (Must be above single-letter rules)
    (LeftCtx:'';  Letters:'AW';  RightCtx:'';    Phonemes:'AO'),     // "Awful"
    (LeftCtx:'';  Letters:'AI';  RightCtx:'';    Phonemes:'EY'),     // "Wait"
    (LeftCtx:'';  Letters:'AY';  RightCtx:'';    Phonemes:'EY'),     // "Way"
    (LeftCtx:'';  Letters:'AU';  RightCtx:'';    Phonemes:'AO'),     // "Author"
    (LeftCtx:'';  Letters:'ALL'; RightCtx:' ';   Phonemes:'AO LL'),  // "Ball"
    (LeftCtx:'';  Letters:'ALK'; RightCtx:'';    Phonemes:'AO KK'),  // "Walk"
    (LeftCtx:' '; Letters:'ABLE';RightCtx:'';    Phonemes:'EY BB LL'),// "Able"
    (LeftCtx:' '; Letters:'A';   RightCtx:'BOU'; Phonemes:'AX'), // "About", "Abound"
    (LeftCtx:' '; Letters:'A';   RightCtx:'BOV'; Phonemes:'AX'), // "Above"
    (LeftCtx:'';  Letters:'APE'; RightCtx:'';    Phonemes:'EY PP'),  // "Shape"

    // MAGIC E
    (LeftCtx:'^'; Letters:'A';   RightCtx:'^E '; Phonemes:'EY'),     // "Wake", "Bake"

    // SPECIFIC SUFFIXES
    (LeftCtx:'';  Letters:'A';   RightCtx:'KER ';Phonemes:'EY'),     // "Baker"
    (LeftCtx:'';  Letters:'A';   RightCtx:'PER ';Phonemes:'EY'),     // "Paper"
    (LeftCtx:'';  Letters:'A';   RightCtx:'LER ';Phonemes:'EY'),     // "Baler"
    (LeftCtx:'';  Letters:'A';   RightCtx:'VER ';Phonemes:'EY'),     // "Waver"
    (LeftCtx:'';  Letters:'A';   RightCtx:'ZER ';Phonemes:'EY'),     // "Razor"
    (LeftCtx:'';  Letters:'A';   RightCtx:'GER ';Phonemes:'EY'),     // "Pager"

    // SINGLE-LETTER CONTEXTS
    (LeftCtx:'W'; Letters:'A';   RightCtx:'R';   Phonemes:'AO'),     // "Warm", "Ward"
    (LeftCtx:'W'; Letters:'A';   RightCtx:'';    Phonemes:'AA'),     // "Want", "Wash" (Now safely falls through!)
    (LeftCtx:'';  Letters:'A';   RightCtx:'WA';  Phonemes:'AX'),     // "Away"
    (LeftCtx:'#'; Letters:'AL';  RightCtx:' ';   Phonemes:'AX LL'),  // "Vocal"
    (LeftCtx:'#'; Letters:'ALS'; RightCtx:' ';   Phonemes:'AX LL ZZ'),// "Vocals"
    (LeftCtx:'';  Letters:'AL';  RightCtx:'^';   Phonemes:'AO LL'),  // "Almost"
    (LeftCtx:'';  Letters:'AL';  RightCtx:'#';   Phonemes:'AX LL'),  // "Allow"
    (LeftCtx:'';  Letters:'A';   RightCtx:'T';   Phonemes:'AE'),
    (LeftCtx:'';  Letters:'A';   RightCtx:'#';   Phonemes:'EY'),     // "Chaos"

    // DEFAULT A
    (LeftCtx:'';  Letters:'A';   RightCtx:'';    Phonemes:'AE'),     // "Cat", "Bat"


    // -------------------------------------------------------
    // B
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'BB'; RightCtx:''; Phonemes:'BB'),            // double B
    (LeftCtx:''; Letters:'B';  RightCtx:' '; Phonemes:'BB'),           // word-final
    (LeftCtx:''; Letters:'B';  RightCtx:''; Phonemes:'BB'),            // default

    // -------------------------------------------------------
    // C
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'CIA'; RightCtx:''; Phonemes:'SH AX'),        // "social"
    (LeftCtx:''; Letters:'CI';  RightCtx:''; Phonemes:'SS IH'),        // "city"
    (LeftCtx:''; Letters:'CE';  RightCtx:''; Phonemes:'SS'),           // "ice"
    (LeftCtx:''; Letters:'CY';  RightCtx:''; Phonemes:'SS IH'),        // "icy"
    (LeftCtx:''; Letters:'CK';  RightCtx:''; Phonemes:'KK'),           // "back"
    (LeftCtx:''; Letters:'CO'; RightCtx:'M'; Phonemes:'KK AH'),        // "come"
    (LeftCtx:''; Letters:'CH';  RightCtx:''; Phonemes:'CH'),           // "church"
    (LeftCtx:''; Letters:'C';   RightCtx:'+'; Phonemes:'SS'),          // before front vowel
    (LeftCtx:''; Letters:'C';   RightCtx:''; Phonemes:'KK'),           // default

    // -------------------------------------------------------
    // D
    // -------------------------------------------------------
    (LeftCtx:'#'; Letters:'DED'; RightCtx:' '; Phonemes:'DD IH DD'),
    (LeftCtx:'.'; Letters:'DE';  RightCtx:'^#'; Phonemes:'DD IH'),
    (LeftCtx:'#'; Letters:'D';   RightCtx:' ';  Phonemes:'DD'),
    (LeftCtx:'';  Letters:'DG';  RightCtx:''; Phonemes:'JH'),
    (LeftCtx:'';  Letters:'DIV'; RightCtx:''; Phonemes:'DD IH VV'),
    (LeftCtx:'';  Letters:'D';   RightCtx:''; Phonemes:'DD'),


    // -------------------------------------------------------
    // E
    // -------------------------------------------------------

    // 1. MULTI-LETTER RULES (Must always be first!)
    (LeftCtx:'M'; Letters:'EA';  RightCtx:'S';   Phonemes:'EH'),     // "Measure"
    (LeftCtx:'L'; Letters:'EA';  RightCtx:'S';   Phonemes:'EH'),     // "Pleasure"
    (LeftCtx:'';  Letters:'EVEN';RightCtx:'';    Phonemes:'IY VV AH NN'),
    (LeftCtx:'';  Letters:'EW';  RightCtx:'';    Phonemes:'UW'),
    (LeftCtx:'';  Letters:'EY';  RightCtx:'';    Phonemes:'EY'),
    (LeftCtx:'';  Letters:'EE';  RightCtx:'';    Phonemes:'IY'),
    (LeftCtx:'';  Letters:'EA';  RightCtx:'';    Phonemes:'IY'),
    (LeftCtx:'';  Letters:'EI';  RightCtx:'';    Phonemes:'IY'),
    (LeftCtx:'';  Letters:'ER';  RightCtx:'#';   Phonemes:'EH RR'),
    (LeftCtx:'';  Letters:'ER';  RightCtx:'';    Phonemes:'ER'),

    // 2. PAST-TENSE SUFFIXES (-ED)
    (LeftCtx:'T'; Letters:'E';   RightCtx:'D ';  Phonemes:'IX'), // "Wanted", "Melted"
    (LeftCtx:'D'; Letters:'E';   RightCtx:'D ';  Phonemes:'IX'), // "Needed", "Ended"
    (LeftCtx:'#:';Letters:'E';   RightCtx:'D ';  Phonemes:''),   // "Pulled", "Baked" (Silent E if there is an earlier vowel!)

    // 3. MAGIC E & SILENT E
    (LeftCtx:'';  Letters:'E';   RightCtx:'^E '; Phonemes:'IY'), // "Scene", "Cede"
    (LeftCtx:'#:';Letters:'E';   RightCtx:' ';   Phonemes:''),   // "Make", "Time" (Silent E at the end of a word, protects "Me"/"Be")
    (LeftCtx:'';  Letters:'E';   RightCtx:' ';   Phonemes:'IY'),     // "Be", "He", "Me"

    // 4. SINGLE LETTER FALLBACKS
    (LeftCtx:'#'; Letters:'E';   RightCtx:'^#';  Phonemes:'IH'), // "Telephone"
    (LeftCtx:'';  Letters:'E';   RightCtx:'#';   Phonemes:'IY'), // "Neon"
    (LeftCtx:'';  Letters:'E';   RightCtx:'';    Phonemes:'EH'), // "Bed", "Red", "Pet" (Default)

    // -------------------------------------------------------
    // F
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'FUL'; RightCtx:''; Phonemes:'FF UH LL'),     // "full"
    (LeftCtx:''; Letters:'FF';  RightCtx:''; Phonemes:'FF'),           // double F
    (LeftCtx:''; Letters:'F';   RightCtx:''; Phonemes:'FF'),           // default

    // -------------------------------------------------------
    // G
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'GIV'; RightCtx:''; Phonemes:'GG IH VV'),     // "give"
    (LeftCtx:' '; Letters:'G';  RightCtx:'I#'; Phonemes:'GG'),         // "giant" word-initial
    (LeftCtx:'';  Letters:'GE'; RightCtx:'T';  Phonemes:'GG EH'),      // "get"
    (LeftCtx:'';  Letters:'G';  RightCtx:'+';  Phonemes:'JH'),         // "gem" before front vowel
    (LeftCtx:'';  Letters:'GG'; RightCtx:'';   Phonemes:'GG'),         // double G
    (LeftCtx:'';  Letters:'GH'; RightCtx:'';   Phonemes:''),           // "through" silent GH
    (LeftCtx:'';  Letters:'G';  RightCtx:'';   Phonemes:'GG'),         // default

    // -------------------------------------------------------
    // H
    // -------------------------------------------------------
    (LeftCtx:' '; Letters:'HOW'; RightCtx:''; Phonemes:'HH AW'),       // "how"
    (LeftCtx:' '; Letters:'HAV'; RightCtx:''; Phonemes:'HH AE VV'),    // "have"
    (LeftCtx:'';  Letters:'H';  RightCtx:'#';  Phonemes:'HH'),         // default before vowel
    (LeftCtx:'';  Letters:'H';  RightCtx:'';   Phonemes:''),           // silent H elsewhere

    // -------------------------------------------------------
    // I
    // -------------------------------------------------------
    (LeftCtx:'';  Letters:'I';   RightCtx:'^E '; Phonemes:'AY'),  // "quite", "bite", "hide", "mile"
    (LeftCtx:'';  Letters:'I';   RightCtx:'^ES ';Phonemes:'AY'),  // "bites", "hides", "miles"
    (LeftCtx:'';  Letters:'I';   RightCtx:'^ED ';Phonemes:'AY'),  // "quited", "bited" (catches suffixes)
    (LeftCtx:'';  Letters:'IN';  RightCtx:' ';   Phonemes:'IH NN'),
    (LeftCtx:'';  Letters:'IN';  RightCtx:'^';   Phonemes:'IH NN'),
    (LeftCtx:'';  Letters:'ING'; RightCtx:' ';   Phonemes:'IH NX'),
    (LeftCtx:'';  Letters:'IGH'; RightCtx:'';    Phonemes:'AY'),
    (LeftCtx:'';  Letters:'ILD'; RightCtx:'';    Phonemes:'AY LL DD'),
    (LeftCtx:'';  Letters:'IGN'; RightCtx:' ';   Phonemes:'AY NN'),
    (LeftCtx:'';  Letters:'IGN'; RightCtx:'^';   Phonemes:'IH GG NN'),
    (LeftCtx:'';  Letters:'ING'; RightCtx:'^';   Phonemes:'IH NX GG'),
    (LeftCtx:'';  Letters:'IGHT';RightCtx:'';    Phonemes:'AY TT'),
    (LeftCtx:'^'; Letters:'I';   RightCtx:'^E';  Phonemes:'AY'),
    (LeftCtx:'';  Letters:'IE';  RightCtx:'T';   Phonemes:'AY EH'),
    (LeftCtx:'';  Letters:'IE';  RightCtx:'';    Phonemes:'IY'),
    (LeftCtx:'';  Letters:'I';   RightCtx:'#';   Phonemes:'AY'),
    (LeftCtx:'';  Letters:'I';   RightCtx:'';    Phonemes:'IH'),

    // -------------------------------------------------------
    // J
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'J'; RightCtx:''; Phonemes:'JH'),             // default

    // -------------------------------------------------------
    // K
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'KN'; RightCtx:''; Phonemes:'NN'),            // "know"
    (LeftCtx:''; Letters:'K';  RightCtx:''; Phonemes:'KK'),            // default

    // -------------------------------------------------------
    // L
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'LL'; RightCtx:''; Phonemes:'LL'),            // double L - single phoneme
    (LeftCtx:''; Letters:'LY'; RightCtx:' '; Phonemes:'LL IY'),        // "-ly" suffix
    (LeftCtx:''; Letters:'L';  RightCtx:'';  Phonemes:'LL'),           // default

    // -------------------------------------------------------
    // M
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'MOV'; RightCtx:''; Phonemes:'MM UW VV'),     // "move"
    (LeftCtx:''; Letters:'MM';  RightCtx:''; Phonemes:'MM'),           // double M
    (LeftCtx:''; Letters:'M';   RightCtx:''; Phonemes:'MM'),           // default

    // -------------------------------------------------------
    // N
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'NG';  RightCtx:'#'; Phonemes:'NX GG'),       // "anger"
    (LeftCtx:''; Letters:'NG';  RightCtx:' '; Phonemes:'NX'),          // "sing"
    (LeftCtx:''; Letters:'NG';  RightCtx:'';  Phonemes:'NX GG'),       // "long"
    (LeftCtx:''; Letters:'NK';  RightCtx:'';  Phonemes:'NX KK'),       // "think"
    (LeftCtx:''; Letters:'NOW'; RightCtx:' '; Phonemes:'NN AW'),       // "now"
    (LeftCtx:''; Letters:'NN';  RightCtx:'';  Phonemes:'NN'),          // double N
    (LeftCtx:''; Letters:'N';   RightCtx:'';  Phonemes:'NN'),          // default

    // -------------------------------------------------------
    // O
    // -------------------------------------------------------
    (LeftCtx:'';  Letters:'OF';  RightCtx:' ';   Phonemes:'AH VV'),
    (LeftCtx:'';  Letters:'OFT'; RightCtx:'';    Phonemes:'AO FF TT'),
    (LeftCtx:'';  Letters:'OI';  RightCtx:'NG';  Phonemes:'OW IH'),
    (LeftCtx:'';  Letters:'OI';  RightCtx:'';    Phonemes:'OY'),
    (LeftCtx:'';  Letters:'OW';  RightCtx:'';    Phonemes:'OW'),
    (LeftCtx:'';  Letters:'OUR'; RightCtx:'';    Phonemes:'AO RR'),
    (LeftCtx:'';  Letters:'OU';  RightCtx:'';    Phonemes:'AW'),
    (LeftCtx:'';  Letters:'OE';  RightCtx:'';    Phonemes:'OW'),
    (LeftCtx:'';  Letters:'OO';  RightCtx:'';    Phonemes:'UW'),
    (LeftCtx:'';  Letters:'OA';  RightCtx:'';    Phonemes:'OW'),
    (LeftCtx:'';  Letters:'OR';  RightCtx:'#';   Phonemes:'AO RR'),
    (LeftCtx:'';  Letters:'OR';  RightCtx:'';    Phonemes:'AO RR'),
    (LeftCtx:' '; Letters:'ONE'; RightCtx:' ';   Phonemes:'WW AH NN'),
    (LeftCtx:'';  Letters:'O';   RightCtx:'^E '; Phonemes:'OW'),
    (LeftCtx:'#'; Letters:'O';   RightCtx:'^E';  Phonemes:'OW'),
    (LeftCtx:'#'; Letters:'O';   RightCtx:' ';   Phonemes:'OW'),
    (LeftCtx:'';  Letters:'O';   RightCtx:'#';   Phonemes:'OW'),
    (LeftCtx:'';  Letters:'O';   RightCtx:' ';   Phonemes:'OW'),
    (LeftCtx:'';  Letters:'O';   RightCtx:'CIA'; Phonemes:'OW'),     // "Social", "Associate"
    (LeftCtx:'';  Letters:'O';   RightCtx:'';    Phonemes:'AA'), // FIXED: Default O is "hot/cot", not "aww".

    // -------------------------------------------------------
    // P
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'PH';  RightCtx:''; Phonemes:'FF'),           // "phone"
    (LeftCtx:''; Letters:'PP';  RightCtx:''; Phonemes:'PP'),           // double P
    (LeftCtx:''; Letters:'P';   RightCtx:''; Phonemes:'PP'),           // default

    // -------------------------------------------------------
    // Q
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'QU'; RightCtx:''; Phonemes:'KK WW'),         // "queen"
    (LeftCtx:''; Letters:'Q';  RightCtx:''; Phonemes:'KK'),            // default

    // -------------------------------------------------------
    // R
    // -------------------------------------------------------
    (LeftCtx:' ';Letters:'RE'; RightCtx:'^#'; Phonemes:'RR IY'),       // "repeat"
    (LeftCtx:''; Letters:'R';  RightCtx:'';   Phonemes:'RR'),          // default

    // -------------------------------------------------------
    // S
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'SCE'; RightCtx:''; Phonemes:'SS'),
    (LeftCtx:''; Letters:'SCI'; RightCtx:''; Phonemes:'SS'),
    (LeftCtx:''; Letters:'SH';  RightCtx:''; Phonemes:'SH'),
    (LeftCtx:'#'; Letters:'SION';RightCtx:''; Phonemes:'ZH AX NN'),
    (LeftCtx:'';  Letters:'SIA'; RightCtx:''; Phonemes:'ZH AX'),
    (LeftCtx:'#'; Letters:'S'; RightCtx:' '; Phonemes:'ZZ'),
    (LeftCtx:'@'; Letters:'S'; RightCtx:' '; Phonemes:'ZZ'),
    (LeftCtx:'';  Letters:'SS'; RightCtx:'';  Phonemes:'SS'),
    (LeftCtx:'';  Letters:'STR';RightCtx:'';  Phonemes:'SS TT RR'),
    (LeftCtx:'#'; Letters:'SURE';RightCtx:'';    Phonemes:'ZH ER'),  // "Measure", "Treasure"
    (LeftCtx:'U'; Letters:'S';   RightCtx:'E ';  Phonemes:'ZZ'),     // "Use" (verb), "Fuse"
    (LeftCtx:'';  Letters:'S';  RightCtx:'';  Phonemes:'SS'),
    // -------------------------------------------------------
    // T
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'TION';RightCtx:''; Phonemes:'SH AX NN'),
    (LeftCtx:''; Letters:'THR'; RightCtx:''; Phonemes:'TH RR'),
    (LeftCtx:' '; Letters:'TH'; RightCtx:''; Phonemes:'DH'),
    (LeftCtx:'#'; Letters:'TH'; RightCtx:''; Phonemes:'DH'),
    (LeftCtx:'';  Letters:'TH'; RightCtx:''; Phonemes:'TH'),
    (LeftCtx:''; Letters:'TIA'; RightCtx:''; Phonemes:'SH AX'),
    (LeftCtx:''; Letters:'TCH'; RightCtx:''; Phonemes:'CH'),
    (LeftCtx:''; Letters:'TT';  RightCtx:''; Phonemes:'TT'),
    (LeftCtx:''; Letters:'T';   RightCtx:''; Phonemes:'TT'),

    // -------------------------------------------------------
    // U
    // -------------------------------------------------------
    (LeftCtx:'P'; Letters:'U';   RightCtx:'LL';  Phonemes:'UH'),     // "Pulled", "Pull"
    (LeftCtx:'B'; Letters:'U';   RightCtx:'LL';  Phonemes:'UH'),     // "Bull"
    (LeftCtx:'F'; Letters:'U';   RightCtx:'LL';  Phonemes:'UH'),     // "Full"
    (LeftCtx:'';  Letters:'U';   RightCtx:'^E '; Phonemes:'YY UW'),  // "Use", "Mute" (Magic E for U)
    (LeftCtx:'';  Letters:'UN';  RightCtx:'I';   Phonemes:'YY UW NN'),
    (LeftCtx:'';  Letters:'UN';  RightCtx:'^';   Phonemes:'AH NN'),
    (LeftCtx:'';  Letters:'UPON';RightCtx:'';    Phonemes:'AX PP AO NN'),
    (LeftCtx:'';  Letters:'UR';  RightCtx:'#';   Phonemes:'UH RR'),
    (LeftCtx:'';  Letters:'UR';  RightCtx:'';    Phonemes:'ER'),
    (LeftCtx:'';  Letters:'UL';  RightCtx:' ';   Phonemes:'AX LL'),
    (LeftCtx:'';  Letters:'ULL'; RightCtx:' ';   Phonemes:'UH LL'),
    (LeftCtx:'';  Letters:'UY';  RightCtx:'';    Phonemes:'AY'),
    (LeftCtx:'';  Letters:'U';   RightCtx:'#';   Phonemes:'YY UW'),
    (LeftCtx:'';  Letters:'U';   RightCtx:'';    Phonemes:'AH'),

    // -------------------------------------------------------
    // V
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'VIEW';RightCtx:''; Phonemes:'VV YY UW'),     // "view"
    (LeftCtx:''; Letters:'V';   RightCtx:''; Phonemes:'VV'),           // default

    // -------------------------------------------------------
    // W
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'WR';  RightCtx:''; Phonemes:'RR'),           // "write"
    (LeftCtx:''; Letters:'WH';  RightCtx:''; Phonemes:'WW'),           // "where"
    (LeftCtx:''; Letters:'WOR'; RightCtx:'^';Phonemes:'WW ER'),        // "word"
    (LeftCtx:''; Letters:'WOR'; RightCtx:'#';Phonemes:'WW AO RR'),     // "wore"
    (LeftCtx:''; Letters:'W';   RightCtx:'';  Phonemes:'WW'),          // default

    // -------------------------------------------------------
    // X
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'X';  RightCtx:''; Phonemes:'KK SS'),         // default

    // -------------------------------------------------------
    // Y
    // -------------------------------------------------------
    (LeftCtx:'';  Letters:'YOUNG';RightCtx:'';   Phonemes:'YY AH NX'),
    (LeftCtx:'';  Letters:'YOU'; RightCtx:'';    Phonemes:'YY UW'),
    (LeftCtx:'';  Letters:'YES'; RightCtx:'';    Phonemes:'YY EH SS'),
    (LeftCtx:'';  Letters:'Y';   RightCtx:'^E '; Phonemes:'AY'),
    (LeftCtx:'';  Letters:'Y';   RightCtx:'#';   Phonemes:'YY'),
    (LeftCtx:'';  Letters:'Y';   RightCtx:' ';   Phonemes:'IY'),
    (LeftCtx:'';  Letters:'Y';   RightCtx:'';    Phonemes:'IH'),

    // -------------------------------------------------------
    // Z
    // -------------------------------------------------------
    (LeftCtx:''; Letters:'Z'; RightCtx:''; Phonemes:'ZZ'),             // default

    // -------------------------------------------------------
    // Common whole-word overrides - matched before letter rules
    // These fire in ApplyLTSRules before the main loop
    // (listed here for reference; implemented as a separate table)
    // -------------------------------------------------------
    (LeftCtx:''; Letters:''; RightCtx:''; Phonemes:'')                 // sentinel
  );

// ---------------------------------------------------------------------------
// Whole-word exception table
// Irregular words whose LTS rules would get wrong
// ---------------------------------------------------------------------------

Const
  WordExceptionCount = 152;

  WordExceptions: Array[0..WordExceptionCount-1, 0..1] of aString = (
    ('THE',      'DH AX'),
    ('I',        'AY'),
    ('SPECBAS', 'SS PP EH KK BB AE SS'),
    ('A',        'AX'),
    ('AND',      'AE NN DD'),
    ('OF',       'AH VV'),
    ('TO',       'TT UW'),
    ('IN',       'IH NN'),
    ('IS',       'IH ZZ'),
    ('IT',       'IH TT'),
    ('AS',       'AE ZZ'),
    ('AT',       'AE TT'),
    ('BE',       'BB IY'),
    ('BY',       'BB AY'),
    ('HE',       'HH IY'),
    ('ME',       'MM IY'),
    ('WE',       'WW IY'),
    ('DO',       'DD UW'),
    ('GO',       'GG OW'),
    ('NO',       'NN OW'),
    ('SO',       'SS OW'),
    ('UP',       'AH PP'),
    ('IF',       'IH FF'),
    ('OR',       'AO RR'),
    ('AN',       'AE NN'),
    ('MY',       'MM AY'),
    ('HAS',      'HH AE ZZ'),
    ('HIS',      'HH IH ZZ'),
    ('HER',      'HH ER'),
    ('WAS',      'WW AH ZZ'),
    ('ARE',      'AA RR'),
    ('FOR',      'FF AO RR'),
    ('YOU',      'YY UW'),
    ('WITH',     'WW IH DH'),
    ('THIS',     'DH IH SS'),
    ('THAT',     'DH AE TT'),
    ('FROM',     'FF RR AH MM'),
    ('THEY',     'DH EY'),
    ('HAVE',     'HH AE VV'),
    ('HAD',      'HH AE DD'),
    ('NOT',      'NN AO TT'),
    ('BUT',      'BB AH TT'),
    ('ALL',      'AO LL'),
    ('ONE',      'WW AH NN'),
    ('TWO',      'TT UW'),
    ('WHO',      'HH UW'),
    ('HOW',      'HH AW'),
    ('NOW',      'NN AW'),
    ('OUR',      'AW ER'),
    ('OUT',      'AW TT'),
    ('THEIR',    'DH EH RR'),
    ('THERE',    'DH EH RR'),
    ('WHAT',     'WW AH TT'),
    ('WHEN',     'WW EH NN'),
    ('WHICH',    'WW IH CH'),
    ('SAID',     'SS EH DD'),
    ('WERE',     'WW ER'),
    ('YOUR',     'YY AO RR'),
    ('BEEN',     'BB IH NN'),
    ('COULD',    'KK UH DD'),
    ('WOULD',    'WW UH DD'),
    ('SHOULD',   'SH UH DD'),
    ('LATER',    'LL EY TT ER'),
    ('WATER',    'WW AO TT ER'),
    ('PAPER',    'PP EY PP ER'),
    ('MAKE',     'MM EY KK'),
    ('TAKE',     'TT EY KK'),
    ('CAME',     'KK EY MM'),
    ('GAME',     'GG EY MM'),
    ('NAME',     'NN EY MM'),
    ('SAME',     'SS EY MM'),
    ('LATE',     'LL EY TT'),
    ('FATE',     'FF EY TT'),
    ('GATE',     'GG EY TT'),
    ('HATE',     'HH EY TT'),
    ('RATE',     'RR EY TT'),
    ('DATE',     'DD EY TT'),
    ('SEVEN',    'SS EH VV AH NN'),
    ('KEYBOARD', 'KK IY BB AO RR DD'),
    ('TOGETHER', 'TT AX GG EH DH ER'),
    ('ANOTHER',  'AX NN AH DH ER'),
    ('SOMETHING','SS AH MM TH IH NX'),
    ('SOME',     'SS AH MM'),
    ('COME',     'KK AH MM'),
    ('DONE',     'DD AH NN'),
    ('NONE',     'NN AH NN'),
    ('LOVE',     'LL AH VV'),
    ('ABOVE',    'AX BB AH VV'),
    ('DOVE',     'DD AH VV'),
    ('GIVE',     'GG IH VV'),
    ('LIVE',     'LL IH VV'),
    ('WEATHER',  'WW EH DH ER'),
    ('FEATHER',  'FF EH DH ER'),
    ('LEATHER',  'LL EH DH ER'),
    ('BREAD',    'BB RR EH DD'),
    ('DEAD',     'DD EH DD'),
    ('HEAD',     'HH EH DD'),
    ('HEAVY',    'HH EH VV IY'),
    ('READY',    'RR EH DD IY'),
    ('ALREADY',  'AO LL RR EH DD IY'),
    ('TYPE',     'TT AY PP'),
    ('BYTE',     'BB AY TT'),
    ('STYLE',    'SS TT AY LL'),
    ('EIGHT',    'EY TT'),
    ('NIGHT',    'NN AY TT'),
    ('LIGHT',    'LL AY TT'),
    ('RIGHT',    'RR AY TT'),
    ('MIGHT',    'MM AY TT'),
    ('SIGHT',    'SS AY TT'),
    ('FIGHT',    'FF AY TT'),
    ('TIGHT',    'TT AY TT'),
    ('BRIGHT',   'BB RR AY TT'),
    ('FLIGHT',   'FF LL AY TT'),
    ('KNIGHT',   'NN AY TT'),
    ('WEIGHT',   'WW EY TT'),
    ('HEIGHT',   'HH AY TT'),
    ('QUESTION', 'KK WW EH SS CH AX NN'),
    ('THREE',    'TH RR IY'),
    ('PHONE',    'FF OW NN'),
    ('PEOPLE',   'PP IY PP LL'),
    ('THROUGH',  'TH RR UW'),
    ('THOUGHT',  'TH AO TT'),
    ('THOUGH',   'DH OW'),
    ('ENOUGH',   'IH NN AH FF'),
    ('COUGH',    'KK AO FF'),
    ('ROUGH',    'RR AH FF'),
    ('TOUGH',    'TT AH FF'),
    ('SHE',      'SH IY'),
    ('LIST',     'LL IH SS TT'),
    ('RUN',      'RR AH NN'),
    ('PRINT',    'PP RR IH NN TT'),
    ('INPUT',    'IH NN PP AH TT'),
    ('GOTO',     'GG OW TT OW'),
    ('GOSUB',    'GG OW SS AH BB'),
    ('RETURN',   'RR IH TT ER NN'),
    ('STOP',     'SS TT AO PP'),
    ('END',      'EH NN DD'),
    ('NEW',      'NN YY UW'),
    ('LOAD',     'LL OW DD'),
    ('SAVE',     'SS EY VV'),
    ('CLEAR',    'KK LL IY RR'),
    ('LET',      'LL EH TT'),
    ('NEXT',     'NN EH KK SS TT'),
    ('THEN',     'DH EH NN'),
    ('ELSE',     'EH LL SS'),
    ('DIM',      'DD IH MM'),
    ('COMPUTER', 'KK AH MM PP YY UW TT ER'),
    ('REM',      'RR EH MM'),
    ('RECEIVE',  'RR IY SS IY VV'),
    ('BOY',      'BB OY'),
    ('COW',      'KK AW'),
    ('WALK',     'WW AO KK')
  );

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

      '@': // suffix consonant (D G J L N R S T Z)
        Begin
          If SP_Util.Pos(s[si], 'BDGJLMNRVZ') = 0 Then
            Begin Result := False; Exit; End;
          Inc(si, Dir);
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
  Begin
    If p = '' Then Exit;
    If Result <> '' Then Result := Result + ' ';
    Result := Result + p;
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
      Emit('PA3'); Inc(i); Continue;
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

// ---------------------------------------------------------------------------
// Stress mark assignment
// Amiga translator.library always appended a stress digit to every vowel
// phoneme (0=unstressed, 1=normal, 2=primary stress).  We replicate that
// here as a post-pass over the raw phoneme string from ApplyLTSRules.
//
// Rules (applied per inter-word group, words separated by PA tokens):
//   - Phoneme string matches a known function-word pattern -> all vowels: 0
//   - Schwa-type vowels (AX, IX)                          -> always: 0
//   - First non-schwa vowel in a content word             -> 2
//   - Subsequent non-schwa vowels in that word            -> 1
// ---------------------------------------------------------------------------

Const
  // Phoneme strings for closed-class function words.
  // Must match the post-diphthong-fix output of our translator exactly.
  FWCount = 44;
  FunctionWordPhonemes: Array[0..FWCount-1] of aString = (
    'DH AX',        // THE
    'AX',           // A
    'AE NN DD',     // AND
    'AH VV',        // OF
    'TT UW',        // TO
    'IH NN',        // IN
    'IH ZZ',        // IS
    'IH TT',        // IT
    'AE ZZ',        // AS
    'AE TT',        // AT
    'BB IY',        // BE
    'BB AY',        // BY
    'HH IY',        // HE
    'MM IY',        // ME
    'WW IY',        // WE
    'DD UW',        // DO
    'IH FF',        // IF
    'AO RR',        // OR
    'AE NN',        // AN
    'HH AE ZZ',     // HAS
    'HH IH ZZ',     // HIS
    'HH ER',        // HER
    'WW AH ZZ',     // WAS
    'AA RR',        // ARE
    'FF AO RR',     // FOR
    'YY UW',        // YOU
    'WW IH DH',     // WITH
    'DH IH SS',     // THIS
    'DH AE TT',     // THAT
    'FF RR AH MM',  // FROM
    'DH EY',        // THEY
    'HH AE VV',     // HAVE
    'HH AE DD',     // HAD
    'BB AH TT',     // BUT
    'DH EH RR',     // THEIR / THERE (same phonemes)
    'WW EH NN',     // WHEN
    'WW IH CH',     // WHICH
    'WW ER',        // WERE
    'YY AO RR',     // YOUR
    'BB IH NN',     // BEEN
    'KK UH DD',     // COULD
    'WW UH DD',     // WOULD
    'SH UH DD',     // SHOULD
    'SS OW'         // SO
  );

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
Var
  Tokens:     Array of aString;
  VowelPos:   Array of Integer;
  TokCount:   Integer;
  VowelCount: Integer;
  NSVCount:   Integer;  // non-schwa vowel count in this word
  NSVFound:   Integer;  // how many non-schwa vowels assigned so far
  i, j:       Integer;
  p, q:       Integer;
  Tok:        aString;
  WordStr:    aString;
  WordStart:  Integer;
  WordEnd:    Integer;
  Stress:     Integer;
Begin
  Result := '';
  If Phonemes = '' Then Exit;

  // ---- Tokenise ----
  SetLength(Tokens,   512);
  SetLength(VowelPos,  64);
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

    // PA tokens pass through unchanged
    If IsPausePhoneme(Tokens[i]) Then Begin
      Inc(i);
      Continue;
    End;

    // Find the end of this word group (up to the next PA or end of tokens)
    WordStart := i;
    WordEnd   := i;
    While (WordEnd < TokCount) And Not IsPausePhoneme(Tokens[WordEnd]) Do
      Inc(WordEnd);
    // Tokens[WordStart .. WordEnd-1] form one word

    // Build space-joined phoneme string for function-word lookup
    WordStr := '';
    For j := WordStart To WordEnd - 1 Do Begin
      If WordStr <> '' Then WordStr := WordStr + ' ';
      WordStr := WordStr + Tokens[j];
    End;

    // Collect vowel positions and count non-schwa vowels
    VowelCount := 0;
    NSVCount   := 0;
    For j := WordStart To WordEnd - 1 Do
      If IsVowelPhoneme(Tokens[j]) Then Begin
        If VowelCount < Length(VowelPos) Then Begin
          VowelPos[VowelCount] := j;
          Inc(VowelCount);
        End;
        If Not IsSchwaPhoneme(Tokens[j]) Then Inc(NSVCount);
      End;

    // Append stress digit to each vowel token
    NSVFound := 0;
    For j := 0 To VowelCount - 1 Do Begin
      Tok := Tokens[VowelPos[j]];
      If IsSchwaPhoneme(Tok) Then
        Stress := 0
      Else Begin
        Inc(NSVFound);

        If NSVCount = 1 Then
          Stress := 1        // Monosyllabic word: receives normal baseline stress (IY1)
        Else If NSVFound = 1 Then
          Stress := 2        // Polysyllabic word: primary stress
        Else
          Stress := 1;       // Polysyllabic word: normal stress
      End;
      Tokens[VowelPos[j]] := Tok + aChar(Ord('0') + Stress);
    End;

    i := WordEnd; // jump to the next PA token or end
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

    // Marker 2: stress digit 4-9 not part of a SpecBAS PA4/PA5 token.
    // Digits 6-9 are unconditional; 4-5 only fire when not preceded by 'PA'.
    If (c >= '4') And (c <= '9') Then
      If (c >= '6') Or
         Not ((i >= 3) And (Upper[i-2] = 'P') And (Upper[i-1] = 'A')) Then Begin
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
      If Stress < 0 Then
        Result := Result + Token + '1'    // no digit -> normal stress
      Else If Stress <= 3 Then
        Result := Result + Token + '0'    // light/unstressed
      Else
        Result := Result + Token + '2'    // primary or heavy
    End Else
      Result := Result + Token;

  End;
End;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

Function SP_NarratorTranslate(Const Text: aString): aString;
Var
  Normalised: aString;
  Stressed:   aString;
Begin
  Normalised := NormaliseText(Text);
  Stressed   := AssignStressMarks(ApplyLTSRules(Normalised));
  // Strip PA1 inter-word markers now that stress assignment is complete.
  // ' PA1' handles mid-string and trailing occurrences in one pass;
  // the follow-up trims any PA1 that was at the very start of the string.
  Result := aString(StringReplace(String(Stressed), ' PA1', '', [rfReplaceAll]));
  If Copy(Result, 1, 3) = 'PA1' Then
    If Length(Result) = 3 Then Result := ''
    Else Result := Copy(Result, 5, Length(Result));
End;

end.
