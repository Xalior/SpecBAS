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

unit SP_Sockets;

// TCP/UDP socket support for SpecBAS.
// Sockets are exposed as streams - a connected socket's stream ID can be
// used anywhere a stream ID is accepted, including as the target of OUT.
//
// SOCKET CONNECT host$, port TO var    - TCP client connect
// SOCKET LISTEN  port [,backlog] TO var - TCP server listen socket
// SOCKET ACCEPT  listenid TO var        - block until a client connects
// SOCKET SEND    id, data$             - send raw bytes
// SOCKET RECV    id [,maxbytes] TO var$ - receive bytes (default 4096)
// SOCKET RECV LINE id TO var$          - receive until CRLF
// SOCKET CLOSE   id                   - close (also via STREAM CLOSE)
// SOCKET NOBLOCK id                   - set non-blocking
// SOCKET TIMEOUT id, ms               - set recv timeout (0 = block)
// SOCKET UDP     host$, port TO var    - UDP datagram socket
//
// Query functions:
//   SOCKETSIZE(id)  - bytes available to read
//   SOCKETSTATE(id) - 0=closed/invalid  1=connected  2=listening
//   SOCKETaddr$(id) - "x.x.x.x:port" of remote end
//   SOCKETPORT(id)  - remote port number

{$IFDEF FPC}
  {$MODE Delphi}
  {$IFDEF WINDOWS}
    {$DEFINE SP_WINSOCK}   // FPC on Windows
  {$ENDIF}
{$ELSE}
  {$DEFINE SP_WINSOCK}     // Delphi - always Windows
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses
  SysUtils, SP_SysVars, SP_Errors, SP_Util,
  {$IFDEF SP_WINSOCK}
  WinSock2
  {$ELSE}
  // FIONREAD is declared in termio, not in BaseUnix or Unix. netdb has the
  // name resolver.
  Sockets, BaseUnix, Unix, termio, netdb
  {$ENDIF}
  ;

// Socket state constants
Const
  SP_SOCKET_CLOSED    = 0;
  SP_SOCKET_CONNECTED = 1;
  SP_SOCKET_LISTENING = 2;
  SP_SOCKET_UDP       = 3;

// Create a TCP client socket connected to host:port.
// Returns the stream ID, or -1 on error.
Function  SP_SocketConnect(Const Host: aString; Port: Integer; Var Error: TSP_ErrorCode): Integer;

// Create a TCP server listen socket on the given port.
// Returns the stream ID, or -1 on error.
Function  SP_SocketListen(Port, Backlog: Integer; Var Error: TSP_ErrorCode): Integer;

// Block until an incoming connection arrives on a listening socket.
// Returns the stream ID of the new connection, or -1 on error.
Function  SP_SocketAccept(ListenStreamID: Integer; Var Error: TSP_ErrorCode): Integer;

// Create a UDP socket targeted at host:port.
// Returns the stream ID, or -1 on error.
Function  SP_SocketUDP(Const Host: aString; Port: Integer; Var Error: TSP_ErrorCode): Integer;

// Send raw bytes over a socket stream.
Function  SP_SocketSend(StreamID: Integer; Const Data: aString; Var Error: TSP_ErrorCode): Integer;

// Receive up to MaxBytes bytes from a socket stream.
Function  SP_SocketRecv(StreamID: Integer; MaxBytes: Integer; Var Error: TSP_ErrorCode): aString;

// Receive bytes until CRLF (or LF alone) from a socket stream.
Function  SP_SocketRecvLine(StreamID: Integer; Var Error: TSP_ErrorCode): aString;

// Set a recv timeout in milliseconds. 0 = block indefinitely.
Procedure SP_SocketSetTimeout(StreamID, Ms: Integer; Var Error: TSP_ErrorCode);

// Set non-blocking mode on a socket stream.
Procedure SP_SocketSetNonBlocking(StreamID: Integer; Var Error: TSP_ErrorCode);

// Query functions
Function  SP_SocketSize(StreamID: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_SocketState(StreamID: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_SocketAddr(StreamID: Integer; Var Error: TSP_ErrorCode): aString;
Function  SP_SocketPort(StreamID: Integer; Var Error: TSP_ErrorCode): Integer;

// Called from SP_StreamClose to clean up the socket handle.
Procedure SP_SocketCloseHandle(Handle: NativeInt);

// Network utility helpers
Function  SP_URLEncode(Const s: aString): aString;
Function  SP_URLDecode(Const s: aString): aString;
Function  SP_Base64Encode(Const s: aString): aString;
Function  SP_Base64Decode(Const s: aString): aString;
Function  SP_HTTPGet(Const Host, Path: aString; Port: Integer; Var Error: TSP_ErrorCode): aString;
Function  SP_HTTPPost(Const Host, Path, Body, ContentType: aString; Port: Integer; Var Error: TSP_ErrorCode): aString;

implementation

Uses SP_Streams, SP_Main;

// ---------------------------------------------------------------------------
// Platform-specific helpers
// ---------------------------------------------------------------------------

{$IFDEF SP_WINSOCK}

Type
  TSocket = WinSock2.TSocket;

Procedure InitWinSock;
Var WSAData: TWsaData;
Begin
  WSAStartup($0202, WSAData);
End;

Function ResolveHost(Const Host: aString; Port: Integer; Out Addr: TSockAddrIn): Boolean;
Var
  he: PHostEnt;
  sHost: AnsiString;
Begin
  Result := False;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port   := htons(Port);
  sHost := AnsiString(Host);
  Addr.sin_addr.S_addr := inet_addr(PAnsiChar(sHost));
  If Addr.sin_addr.S_addr = INADDR_NONE Then Begin
    he := gethostbyname(PAnsiChar(sHost));
    If he = Nil Then Exit;
    Addr.sin_addr := PInAddr(he^.h_addr_list^)^;
  End;
  Result := True;
End;

Function LastSockError: Integer;
Begin
  Result := WSAGetLastError;
End;

Const
  INVALID_HANDLE = INVALID_SOCKET;

{$ELSE}

// POSIX / FPC Sockets
Type
  TSocket = Longint;

Const
  INVALID_HANDLE = TSocket(-1);
  INVALID_SOCKET = TSocket(-1);

Procedure InitWinSock;
Begin
  // Nothing needed on POSIX
End;

// Free Pascal names its socket entry points fpSocket, fpBind and so on. The
// code shared with WinSock names socket() alone, so that is the only one
// that needs a name here.
Function socket(Domain, SockType, Protocol: Integer): TSocket;
Begin
  Result := fpSocket(Domain, SockType, Protocol);
End;

// StrToNetAddr answers a dotted quad, and 0.0.0.0 for anything that is not
// one, which is when the name goes to the resolver. It is the network-order
// partner to what netdb returns; the host-order helper alongside it would
// reverse the octets and connect to the wrong machine.
Function ResolveHost(Const Host: aString; Port: Integer; Out Addr: TInetSockAddr): Boolean;
Var
  Entry : THostEntry;
  sHost : AnsiString;
Begin
  Result := False;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port   := htons(Port);
  sHost := AnsiString(Host);
  Addr.sin_addr := StrToNetAddr(sHost);
  If Addr.sin_addr.s_addr = 0 Then Begin
    If Not ResolveHostByName(String(sHost), Entry) Then Exit;
    Addr.sin_addr := Entry.Addr;
  End;
  Result := True;
End;

Function LastSockError: Integer;
Begin
  Result := fpGetErrno;
End;

{$ENDIF}

// ---------------------------------------------------------------------------
// Internal helpers that work on raw socket handles
// ---------------------------------------------------------------------------

Function MakeStreamForSocket(Handle: NativeInt; Const RemoteAddr: aString;
                              State: Integer; Var Error: TSP_ErrorCode): Integer;
Begin
  Result := SP_NewSocketStream(Handle, RemoteAddr, State, Error);
      End;

Function FindSocketStream(StreamID: Integer; Var Error: TSP_ErrorCode): pSP_Stream;
Var
  Idx: Integer;
Begin
  Result := Nil;
  For Idx := 0 To Length(SP_StreamList) - 1 Do
    If SP_StreamList[Idx]^.ID = StreamID Then Begin
      If SP_StreamList[Idx]^.SocketHandle = INVALID_HANDLE Then Begin
        Error.Code := SP_ERR_NOT_A_SOCKET;
        Exit;
      End;
      Result := SP_StreamList[Idx];
      Exit;
    End;
  Error.Code := SP_ERR_INVALID_STREAM_ID;
End;

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

Procedure SP_SocketCloseHandle(Handle: NativeInt);
Begin
  If Handle = INVALID_HANDLE Then Exit;
  {$IFDEF SP_WINSOCK}
  closesocket(TSocket(Handle));
  {$ELSE}
  fpClose(TSocket(Handle));
  {$ENDIF}
End;

Function SP_SocketConnect(Const Host: aString; Port: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  ErrCode: Integer;
  Sock : TSocket;
  {$IFDEF SP_WINSOCK}
  Addr : TSockAddrIn;
  {$ELSE}
  Addr : TInetSockAddr;
  {$ENDIF}
Begin
  Result := -1;
  InitWinSock;

  If Not ResolveHost(Host, Port, Addr) Then Begin
    Error.Code := SP_ERR_SOCKET_CONNECT;
    ERRStr     := 'Could not resolve host: ' + Host;
    Exit;
  End;

  Sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  If Sock = TSocket(INVALID_HANDLE) Then Begin
    Error.Code := SP_ERR_SOCKET_CONNECT;
    {$IFDEF SP_WINSOCK}
    ERRStr := 'Socket creation failed (WSA ' + IntToString(WSAGetLastError) + ')';
    {$ELSE}
    ERRStr     := 'Socket creation failed';
    {$ENDIF}
    Exit;
  End;

  {$IFDEF SP_WINSOCK}
  If WinSock2.connect(Sock, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR Then Begin
    ErrCode := WSAGetLastError;
    SP_SocketCloseHandle(Sock);
    Error.Code := SP_ERR_SOCKET_CONNECT;
    ERRStr     := 'Connect failed to ' + Host + ':' + IntToString(Port) +
                  ' (WSA ' + IntToString(ErrCode) + ')';
    Exit;
  End;
  {$ELSE}
  If fpConnect(Sock, @Addr, SizeOf(Addr)) <> 0 Then Begin
    SP_SocketCloseHandle(Sock);
    Error.Code := SP_ERR_SOCKET_CONNECT;
    ERRStr     := 'Connect failed to ' + Host + ':' + IntToString(Port);
    Exit;
  End;
  {$ENDIF}

  Result := MakeStreamForSocket(Sock,
              Host + ':' + IntToString(Port),
              SP_SOCKET_CONNECTED, Error);
End;

Function SP_SocketListen(Port, Backlog: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Sock : TSocket;
  {$IFDEF SP_WINSOCK}
  Addr : TSockAddrIn;
  One  : Integer;
  {$ELSE}
  Addr : TInetSockAddr;
  One  : Integer;
  {$ENDIF}
Begin
  Result := -1;
  InitWinSock;

  Sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  If Sock = TSocket(INVALID_HANDLE) Then Begin
    Error.Code := SP_ERR_SOCKET_LISTEN;
    Exit;
  End;

  One := 1;
  {$IFDEF SP_WINSOCK}
  setsockopt(Sock, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family      := AF_INET;
  Addr.sin_port        := htons(Port);
  Addr.sin_addr.S_addr := INADDR_ANY;
  If WinSock2.bind(Sock, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR Then Begin
    closesocket(Sock);
    Error.Code := SP_ERR_SOCKET_LISTEN;
    Exit;
  End;
  If WinSock2.listen(Sock, Backlog) = SOCKET_ERROR Then Begin
    closesocket(Sock);
    Error.Code := SP_ERR_SOCKET_LISTEN;
    Exit;
  End;
  {$ELSE}
  fpsetsockopt(Sock, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port   := htons(Port);
  Addr.sin_addr.s_addr := INADDR_ANY;
  If fpBind(Sock, @Addr, SizeOf(Addr)) <> 0 Then Begin
    fpClose(Sock);
    Error.Code := SP_ERR_SOCKET_LISTEN;
    Exit;
  End;
  If fpListen(Sock, Backlog) <> 0 Then Begin
    fpClose(Sock);
    Error.Code := SP_ERR_SOCKET_LISTEN;
    Exit;
  End;
  {$ENDIF}

  Result := MakeStreamForSocket(Sock, '*:' + IntToString(Port),
                                SP_SOCKET_LISTENING, Error);
End;

Function SP_SocketAccept(ListenStreamID: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  ListenStream : pSP_Stream;
  ClientSock   : TSocket;
  {$IFDEF SP_WINSOCK}
  ClientAddr   : TSockAddrIn;
  {$ELSE}
  ClientAddr   : TInetSockAddr;
  {$ENDIF}
  AddrLen      : Integer;
  RemoteStr    : aString;
Begin
  Result := -1;
  ListenStream := FindSocketStream(ListenStreamID, Error);
  If Not Assigned(ListenStream) Then Exit;

  If ListenStream^.SocketState <> SP_SOCKET_LISTENING Then Begin
    Error.Code := SP_ERR_NOT_A_SOCKET;
    Exit;
  End;

  AddrLen := SizeOf(ClientAddr);
  {$IFDEF SP_WINSOCK}
  ClientSock := WinSock2.accept(TSocket(ListenStream^.SocketHandle),
                                pSockAddr(@ClientAddr), @AddrLen);
  If ClientSock = INVALID_SOCKET Then Begin
  {$ELSE}
  ClientSock := fpAccept(TSocket(ListenStream^.SocketHandle),
                         @ClientAddr, @AddrLen);
  If ClientSock = TSocket(-1) Then Begin
  {$ENDIF}
    Error.Code := SP_ERR_SOCKET_ACCEPT;
    Exit;
  End;

  {$IFDEF SP_WINSOCK}
  RemoteStr := aString(inet_ntoa(ClientAddr.sin_addr)) + ':' +
               IntToString(ntohs(ClientAddr.sin_port));
  {$ELSE}
  RemoteStr := aString(NetAddrToStr(ClientAddr.sin_addr)) + ':' +
               IntToString(ntohs(ClientAddr.sin_port));
  {$ENDIF}

  Result := MakeStreamForSocket(ClientSock, RemoteStr,
                                SP_SOCKET_CONNECTED, Error);
End;

Function SP_SocketUDP(Const Host: aString; Port: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Sock : TSocket;
  {$IFDEF SP_WINSOCK}
  Addr : TSockAddrIn;
  {$ELSE}
  Addr : TInetSockAddr;
  {$ENDIF}
Begin
  Result := -1;
  InitWinSock;

  If Not ResolveHost(Host, Port, Addr) Then Begin
    Error.Code := SP_ERR_SOCKET_CONNECT;
    ERRStr     := 'Could not resolve host: ' + Host;
    Exit;
  End;

  Sock := socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  If Sock = TSocket(INVALID_HANDLE) Then Begin
    Error.Code := SP_ERR_SOCKET_CONNECT;
    Exit;
  End;

  {$IFDEF SP_WINSOCK}
  If WinSock2.connect(Sock, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR Then Begin
  {$ELSE}
  If fpConnect(Sock, @Addr, SizeOf(Addr)) <> 0 Then Begin
  {$ENDIF}
    SP_SocketCloseHandle(Sock);
    Error.Code := SP_ERR_SOCKET_CONNECT;
    ERRStr     := Host + ':' + IntToString(Port);
    Exit;
  End;

  Result := MakeStreamForSocket(Sock, Host + ':' + IntToString(Port),
                                SP_SOCKET_UDP, Error);
End;

Function SP_SocketSend(StreamID: Integer; Const Data: aString; Var Error: TSP_ErrorCode): Integer;
Var
  Stream : pSP_Stream;
  Sent   : Integer;
Begin
  Result := 0;
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;

  If Length(Data) = 0 Then Exit;

  {$IFDEF SP_WINSOCK}
  Sent := WinSock2.send(TSocket(Stream^.SocketHandle),
                        PAnsiChar(@Data[1])^, Length(Data), 0);
  If Sent = SOCKET_ERROR Then Begin
  {$ELSE}
  Sent := fpSend(TSocket(Stream^.SocketHandle),
                 @Data[1], Length(Data), 0);
  If Sent < 0 Then Begin
  {$ENDIF}
    Error.Code := SP_ERR_SOCKET_CLOSED;
    Exit;
  End;

  Result := Sent;
End;

Function SP_SocketRecv(StreamID: Integer; MaxBytes: Integer; Var Error: TSP_ErrorCode): aString;
Var
  Stream : pSP_Stream;
  Buf    : Array of Byte;
  Got    : Integer;
  {$IFDEF SP_WINSOCK}
  FDSet   : TFDSet;
  Timeout : TTimeVal;
  Sel     : Integer;
  {$ELSE}
  FDSet   : TFDSet;
  Timeout : TTimeVal;
  Sel     : Integer;
  {$ENDIF}
Begin
  Result := '';
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;

  If MaxBytes <= 0 Then MaxBytes := 4096;
  SetLength(Buf, MaxBytes);

  // Poll with a short timeout so the interpreter can check BREAKSIGNAL
  // between attempts. Yields to the message loop each iteration.
  Repeat
  {$IFDEF SP_WINSOCK}
    FillChar(FDSet, SizeOf(FDSet), 0);
    FDSet.fd_count    := 1;
    FDSet.fd_array[0] := TSocket(Stream^.SocketHandle);
    Timeout.tv_sec  := 0;
    Timeout.tv_usec := 100000;  // 100ms poll interval
    Sel := WinSock2.select(0, @FDSet, Nil, Nil, @Timeout);
    {$ELSE}
    fpFD_ZERO(FDSet);
    fpFD_SET(TSocket(Stream^.SocketHandle), FDSet);
    Timeout.tv_sec  := 0;
    Timeout.tv_usec := 100000;
    Sel := fpSelect(TSocket(Stream^.SocketHandle)+1, @FDSet, Nil, Nil, @Timeout);
    {$ENDIF}

    If Sel < 0 Then Begin
      Error.Code := SP_ERR_SOCKET_CLOSED;
      Exit;
    End;

    If Sel = 0 Then Begin
      // Timeout - yield and check for break
      CB_Yield(0);
      If BREAKSIGNAL Or QUITMSG Then Begin
        Error.Code := SP_ERR_SOCKET_TIMEOUT;
        Exit;
      End;
      Continue;
    End;

    // Data ready
    {$IFDEF SP_WINSOCK}
  Got := WinSock2.recv(TSocket(Stream^.SocketHandle),
                         PAnsiChar(@Buf[0])^, MaxBytes, 0);
  If Got = SOCKET_ERROR Then Begin
    If WSAGetLastError = WSAETIMEDOUT Then
      Error.Code := SP_ERR_SOCKET_TIMEOUT
    Else
      Error.Code := SP_ERR_SOCKET_CLOSED;
    Exit;
  End;
  {$ELSE}
  Got := fpRecv(TSocket(Stream^.SocketHandle),
                @Buf[0], MaxBytes, 0);
  If Got < 0 Then Begin
    If fpGetErrno = ESysEAGAIN Then
      Error.Code := SP_ERR_SOCKET_TIMEOUT
    Else
      Error.Code := SP_ERR_SOCKET_CLOSED;
    Exit;
  End;
  {$ENDIF}

  If Got = 0 Then Begin
      // Peer closed - mark state and stop looping
    Stream^.SocketState := SP_SOCKET_CLOSED;
      Break;
  End;

    // Append to result and keep reading until no more data
    SetLength(Result, Length(Result) + Got);
    CopyMem(@Result[Length(Result) - Got + 1], @Buf[0], Got);

    // If we got a full buffer there may be more; otherwise stop
    If Got < MaxBytes Then Break;
  Until False;
End;

Function SP_SocketRecvLine(StreamID: Integer; Var Error: TSP_ErrorCode): aString;
Var
  Stream : pSP_Stream;
  Ch     : Byte;
  Got    : Integer;
  {$IFDEF SP_WINSOCK}
  FDSet   : TFDSet;
  Timeout : TTimeVal;
  Sel     : Integer;
  {$ELSE}
  FDSet   : TFDSet;
  Timeout : TTimeVal;
  Sel     : Integer;
  {$ENDIF}
Begin
  Result := '';
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;

  Repeat
    // Poll for one byte with a short timeout so BREAKSIGNAL can interrupt
    Repeat
    {$IFDEF SP_WINSOCK}
      FillChar(FDSet, SizeOf(FDSet), 0);
      FDSet.fd_count    := 1;
      FDSet.fd_array[0] := TSocket(Stream^.SocketHandle);
      Timeout.tv_sec  := 0;
      Timeout.tv_usec := 100000;
      Sel := WinSock2.select(0, @FDSet, Nil, Nil, @Timeout);
      {$ELSE}
      fpFD_ZERO(FDSet);
      fpFD_SET(TSocket(Stream^.SocketHandle), FDSet);
      Timeout.tv_sec  := 0;
      Timeout.tv_usec := 100000;
      Sel := fpSelect(TSocket(Stream^.SocketHandle)+1, @FDSet, Nil, Nil, @Timeout);
      {$ENDIF}

      If Sel < 0 Then Begin
        Error.Code := SP_ERR_SOCKET_CLOSED;
        Exit;
      End;

      If Sel = 0 Then Begin
        CB_Yield(0);
        If BREAKSIGNAL Or QUITMSG Then Begin
          Error.Code := SP_ERR_SOCKET_TIMEOUT;
          Exit;
        End;
      End;
    Until Sel > 0;

    {$IFDEF SP_WINSOCK}
    Got := WinSock2.recv(TSocket(Stream^.SocketHandle), PAnsiChar(@Ch)^, 1, 0);
    If Got = SOCKET_ERROR Then Begin
      If WSAGetLastError = WSAETIMEDOUT Then
        Error.Code := SP_ERR_SOCKET_TIMEOUT
      Else
        Error.Code := SP_ERR_SOCKET_CLOSED;
      Exit;
    End;
    {$ELSE}
    Got := fpRecv(TSocket(Stream^.SocketHandle), @Ch, 1, 0);
    If Got < 0 Then Begin
      If fpGetErrno = ESysEAGAIN Then
        Error.Code := SP_ERR_SOCKET_TIMEOUT
      Else
        Error.Code := SP_ERR_SOCKET_CLOSED;
      Exit;
    End;
    {$ENDIF}
    If Got = 0 Then Begin
      Stream^.SocketState := SP_SOCKET_CLOSED;
      Break;
    End;
    If Ch <> 10 Then
      Result := Result + aChar(Ch);
  Until Ch = 10;

  // Strip trailing CR if CRLF line ending
  If (Length(Result) > 0) And (Result[Length(Result)] = #13) Then
    SetLength(Result, Length(Result) - 1);
End;

Procedure SP_SocketSetTimeout(StreamID, Ms: Integer; Var Error: TSP_ErrorCode);
Var
  Stream : pSP_Stream;
  {$IFDEF SP_WINSOCK}
  TV     : LongWord;
  {$ELSE}
  TV     : TTimeVal;
  {$ENDIF}
Begin
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;

  {$IFDEF SP_WINSOCK}
  TV := LongWord(Ms);
  setsockopt(TSocket(Stream^.SocketHandle), SOL_SOCKET, SO_RCVTIMEO,
             @TV, SizeOf(TV));
  {$ELSE}
  TV.tv_sec  := Ms Div 1000;
  TV.tv_usec := (Ms Mod 1000) * 1000;
  fpsetsockopt(TSocket(Stream^.SocketHandle), SOL_SOCKET, SO_RCVTIMEO,
               @TV, SizeOf(TV));
  {$ENDIF}
End;

Procedure SP_SocketSetNonBlocking(StreamID: Integer; Var Error: TSP_ErrorCode);
Var
  Stream : pSP_Stream;
  {$IFDEF SP_WINSOCK}
  Mode   : u_long;
  {$ELSE}
  Flags  : Integer;
  {$ENDIF}
Begin
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;

  {$IFDEF SP_WINSOCK}
  Mode := 1;
  ioctlsocket(TSocket(Stream^.SocketHandle), Integer(FIONBIO), Mode);
  {$ELSE}
  Flags := FpFcntl(TSocket(Stream^.SocketHandle), F_GETFL, 0);
  FpFcntl(TSocket(Stream^.SocketHandle), F_SETFL, Flags Or O_NONBLOCK);
  {$ENDIF}

  Stream^.NonBlocking := True;
End;

Function SP_SocketSize(StreamID: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Stream : pSP_Stream;
  {$IFDEF SP_WINSOCK}
  Count  : u_long;
  {$ELSE}
  Count  : Integer;
  {$ENDIF}
Begin
  Result := 0;
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;

  Count := 0;
  {$IFDEF SP_WINSOCK}
  If ioctlsocket(TSocket(Stream^.SocketHandle), Integer(FIONREAD), Count) = 0 Then
    Result := Integer(Count);
  {$ELSE}
  If fpIoCtl(TSocket(Stream^.SocketHandle), FIONREAD, @Count) = 0 Then
    Result := Count;
  {$ENDIF}
End;

Function SP_SocketState(StreamID: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Idx    : Integer;
Begin
  Result := SP_SOCKET_CLOSED;
  For Idx := 0 To Length(SP_StreamList) - 1 Do
    If SP_StreamList[Idx]^.ID = StreamID Then Begin
      Result := SP_StreamList[Idx]^.SocketState;
      Exit;
    End;
  // Not found is not an error here - just returns closed (0)
End;

Function SP_SocketAddr(StreamID: Integer; Var Error: TSP_ErrorCode): aString;
Var
  Stream : pSP_Stream;
Begin
  Result := '';
  Stream := FindSocketStream(StreamID, Error);
  If Assigned(Stream) Then
    Result := Stream^.RemoteAddr;
End;

Function SP_SocketPort(StreamID: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Stream : pSP_Stream;
  Colon  : Integer;
Begin
  Result := 0;
  Stream := FindSocketStream(StreamID, Error);
  If Not Assigned(Stream) Then Exit;
  Colon := LastDelimiter(':', String(Stream^.RemoteAddr));
  If Colon > 0 Then
    Result := StrToIntDef(String(Copy(Stream^.RemoteAddr, Colon + 1, 99)), 0);
End;

// ---------------------------------------------------------------------------
// URL encoding / decoding
// ---------------------------------------------------------------------------

Function SP_URLEncode(Const s: aString): aString;
Const
  Safe  : Set of AnsiChar = ['A'..'Z','a'..'z','0'..'9','-','_','.','~'];
  Hex   : Array[0..15] of AnsiChar = '0123456789ABCDEF';
Var
  i : Integer;
  c : AnsiChar;
  b : Byte;
Begin
  Result := '';
  For i := 1 To Length(s) Do Begin
    c := AnsiChar(s[i]);
    If c In Safe Then
      Result := Result + aChar(c)
    Else Begin
      b      := Ord(c);
      Result := Result + '%' + aChar(Hex[b Shr 4]) + aChar(Hex[b And $F]);
    End;
  End;
End;

Function SP_URLDecode(Const s: aString): aString;
Var
  i   : Integer;
  Hex : String;
Begin
  Result := '';
  i := 1;
  While i <= Length(s) Do Begin
    If (s[i] = '%') And (i + 2 <= Length(s)) Then Begin
      Hex    := '$' + String(s[i+1]) + String(s[i+2]);
      Result := Result + aChar(StrToIntDef(Hex, Ord('?')));
      Inc(i, 3);
    End Else If s[i] = '+' Then Begin
      Result := Result + ' ';
      Inc(i);
    End Else Begin
      Result := Result + s[i];
      Inc(i);
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Base64 encode / decode
// ---------------------------------------------------------------------------

Function SP_Base64Encode(Const s: aString): aString;
Const
  Table = aString('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/');
Var
  i, Len, b0, b1, b2 : Integer;
  c2, c3             : aChar;
Begin
  Result := '';
  Len    := Length(s);
  i      := 1;
  While i <= Len Do Begin
    b0 := Ord(s[i]);
    b1 := 0; b2 := 0;
    If i + 1 <= Len Then b1 := Ord(s[i+1]);
    If i + 2 <= Len Then b2 := Ord(s[i+2]);
    If i + 1 <= Len Then c2 := Table[((b1 And $F) Shl 2) Or (b2 Shr 6) + 1]
                    Else c2 := '=';
    If i + 2 <= Len Then c3 := Table[(b2 And $3F) + 1]
                    Else c3 := '=';
    Result := Result +
              Table[(b0 Shr 2) + 1] +
              Table[((b0 And 3) Shl 4) Or (b1 Shr 4) + 1] +
              c2 + c3;
    Inc(i, 3);
  End;
End;

Function SP_Base64Decode(Const s: aString): aString;
Const
  Table = aString('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/');
Var
  i, b0, b1, b2, b3 : Integer;

  Function CharVal(c: aChar): Integer;
  Var p: Integer;
  Begin
    p := Pos(String(c), Table);
    If p > 0 Then Result := p - 1 Else Result := 0;
  End;

Begin
  Result := '';
  i := 1;
  While i + 3 <= Length(s) Do Begin
    b0 := CharVal(s[i]);   b1 := CharVal(s[i+1]);
    b2 := CharVal(s[i+2]); b3 := CharVal(s[i+3]);
    Result := Result + aChar((b0 Shl 2) Or (b1 Shr 4));
    If s[i+2] <> '=' Then
      Result := Result + aChar(((b1 And $F) Shl 4) Or (b2 Shr 2));
    If s[i+3] <> '=' Then
      Result := Result + aChar(((b2 And 3) Shl 6) Or b3);
    Inc(i, 4);
  End;
End;

// ---------------------------------------------------------------------------
// HTTP GET helper
// ---------------------------------------------------------------------------

// SP_HTTPGet performs a complete HTTP/1.0 GET and returns the response body
// (everything after the blank header line). On error returns '' and sets
// Error.Code. Redirects are not followed.

Function SP_HTTPGet(Const Host, Path: aString; Port: Integer; Var Error: TSP_ErrorCode): aString;
Var
  StreamID   : Integer;
  crlf, Line : aString;
  InHeader   : Boolean;
  FirstLine   : Boolean;
  p           : Integer;
Begin
  Result := '';
  crlf   := #13#10;
  HTTPSTATUS := 0;

  StreamID := SP_SocketConnect(Host, Port, Error);
  If Error.Code <> SP_ERR_OK Then Exit;

  // Send request
  SP_SocketSend(StreamID, 'GET ' + Path + ' HTTP/1.0' + crlf +
                           'Host: ' + Host + crlf +
                           'Connection: close' + crlf + crlf, Error);
  If Error.Code <> SP_ERR_OK Then Begin
    SP_StreamClose(StreamID, Error);
    Exit;
  End;

  // Read response - capture status from first line, skip remaining headers, accumulate body
  InHeader := True;
  FirstLine := True;
  While True Do Begin
    Line := SP_SocketRecvLine(StreamID, Error);
    If Error.Code <> SP_ERR_OK Then Break;
    If InHeader Then Begin
      If FirstLine Then Begin
        // "HTTP/1.x NNN reason" - extract the 3-digit status code
        p := Pos(' ', String(Line));
        If p > 0 Then
          HTTPSTATUS := StrToIntDef(String(Copy(Line, p+1, 3)), 0);
        FirstLine := False;
      End Else If Line = '' Then
        InHeader := False;
    End Else
      Result := Result + Line + #10;
    If SP_SocketState(StreamID, Error) = SP_SOCKET_CLOSED Then Break;
  End;

  // Clear timeout/closed errors - EOF after body is normal
  If Error.Code In [SP_ERR_SOCKET_TIMEOUT, SP_ERR_SOCKET_CLOSED] Then
    Error.Code := SP_ERR_OK;

  SP_StreamClose(StreamID, Error);
End;

Function SP_HTTPPost(Const Host, Path, Body, ContentType: aString; Port: Integer; Var Error: TSP_ErrorCode): aString;
Var
  StreamID   : Integer;
  crlf, Line : aString;
  CT         : aString;
  InHeader   : Boolean;
  FirstLine   : Boolean;
  p           : Integer;
Begin
  Result := '';
  crlf       := aString(#13#10);
  HTTPSTATUS := 0;
  CT     := ContentType;
  If CT = '' Then CT := 'application/x-www-form-urlencoded';

  StreamID := SP_SocketConnect(Host, Port, Error);
  If Error.Code <> SP_ERR_OK Then Exit;

  SP_SocketSend(StreamID,
    'POST ' + Path + ' HTTP/1.0' + crlf +
    'Host: ' + Host + crlf +
    'Content-Type: ' + CT + crlf +
    'Content-Length: ' + IntToString(Length(Body)) + crlf +
    'Connection: close' + crlf + crlf +
    Body, Error);
  If Error.Code <> SP_ERR_OK Then Begin
    SP_StreamClose(StreamID, Error);
    Exit;
  End;

  InHeader := True;
  FirstLine := True;
  While True Do Begin
    Line := SP_SocketRecvLine(StreamID, Error);
    If Error.Code <> SP_ERR_OK Then Break;
    If InHeader Then Begin
      If FirstLine Then Begin
        p := Pos(' ', String(Line));
        If p > 0 Then
          HTTPSTATUS := StrToIntDef(String(Copy(Line, p+1, 3)), 0);
        FirstLine := False;
      End Else If Line = '' Then
        InHeader := False;
    End Else
      Result := Result + Line + #10;
    If SP_SocketState(StreamID, Error) = SP_SOCKET_CLOSED Then Break;
  End;

  If Error.Code In [SP_ERR_SOCKET_TIMEOUT, SP_ERR_SOCKET_CLOSED] Then
    Error.Code := SP_ERR_OK;

  SP_StreamClose(StreamID, Error);
End;

Initialization

  InitWinSock;

end.
