(******************************************************************************)
(*                                                                            *)
(* Author      : Uwe Schächterle (Corpsman)                                   *)
(*                                                                            *)
(* This file is part of ntools/npoll                                          *)
(*                                                                            *)
(*  See the file license.md, located under:                                   *)
(*  https://github.com/PascalCorpsman/Software_Licenses/blob/main/license.md  *)
(*  for details about the license.                                            *)
(*                                                                            *)
(*               It is not allowed to change or remove this text from any     *)
(*               source file of the project.                                  *)
(*                                                                            *)
(******************************************************************************)
Unit unpoll;

{$MODE objfpc}{$H+}

Interface

Uses
  Classes, SysUtils, lnet, md5;

{$I ../ntools.inc}

Type

  TPollState = (
    psWaitForConnection, // Wir sind in Lauerstellung ob via UDP was reinkommt, und versuchen darauf eine TCP verbindung auf zu bauen
    psWaitForExecutionCommand, // Die TCP Verbindung ist aufgebaut, nun geht es darum Raus zu bekommen, was NPush von uns will
    psChat,
    psReceiveFiles
    );

  TFileReceiveState = (
    frsWaitForNextFile,
    frsReceiveHeader,
    frsReceiveHeaderFilename,
    frsEvalHeader,
    frsReceiveFile
    );

  TFileReceiveInfo = Record
    FileReceiveState: TFileReceiveState;
    AktualFile: TFileStream;
    Filename: String;
    Position: int64;
    FileSize: int64;
    md5: TMD5Digest;
    CheckMD5: Boolean;
    AppendData: Boolean;
    HeaderHeaderBytes: Array Of Byte;
    HeaderHeaderBytesPointer: integer;
    HeaderBytesFilenameLen: integer;
  End;

  { TNPoll }

  TNPoll = Class
  private
    fudp: TLUdp;
    ftcp: TLTcp;
    fPort: Word;
    frunning: Boolean;
    fState: TPollState;
    fFileReceiveInfo: TFileReceiveInfo;
    fNeedRestart: Boolean;
    Procedure Restart; // Tut so als wäre die App neu gestartet worden
    Procedure OnUDPErrorEvent(Const msg: String; aSocket: TLSocket);
    Procedure OnUDPReceiveEvent(aSocket: TLSocket);

    Procedure OnTCPErrorEvent(Const msg: String; aSocket: TLSocket);
    Procedure OnTCPReceiveEvent(aSocket: TLSocket);
    Procedure OnTCPDisconnect(aSocket: TLSocket);

    Procedure HandleWaitForConnection;
    Procedure HandleChat;
    Procedure HandleReceiveFiles;
    Procedure HandleCheckIfFileNeedsToBeTransfered;
    Procedure ConnectTCPToIP(IP_Address: String);
  public
    ForceIP: String;
    StayOpen: Boolean;
    Constructor create(Port: integer);
    Destructor destroy; override;
    Procedure Execute;
  End;

Implementation

Uses ulogger, crt, math, lazutf8, LazFileUtils;

Function FixDelimeters(value: String): String;
Begin
{$IFDEF Linux}
  result := StringReplace(value, '\', '/', [rfReplaceAll]);
{$ELSE}
  result := StringReplace(value, '/', '\', [rfReplaceAll]);
{$ENDIF}
End;

Function RecursiveCreateDirUTF8(Directory: String): Boolean;
Var
  p: String;
Begin
  If DirectoryExistsUTF8(Directory) Then Begin
    result := true;
    exit;
  End;
  result := CreateDirUTF8(Directory);
  If Not result Then Begin
    p := ExcludeTrailingPathDelimiter(Directory);
    p := ExtractFilePath(p);
    If length(p) <> 0 Then Begin
      result := RecursiveCreateDirUTF8(p);
    End;
    If result Then Begin
      result := CreateDirUTF8(Directory);
    End;
  End;
End;

{ TNPoll }

Constructor TNPoll.create(Port: integer);
Begin
  Inherited create;
  Log('npoll ver. ' + Version, llTrace);
  Log('npoll ver. ' + Version, llInfo);
  StayOpen := false;
  fNeedRestart := false;
  fPort := Port;

  fudp := TLUdp.Create(Nil);
  fudp.OnReceive := @OnudpReceiveEvent;
  fudp.OnError := @OnudpErrorEvent;

  ftcp := TLTcp.Create(Nil);
  ftcp.OnReceive := @OnTCPReceiveEvent;
  ftcp.OnError := @OnTCPErrorEvent;
  ftcp.OnDisconnect := @OnTCPDisconnect;

  fState := psWaitForConnection;
End;

Destructor TNPoll.destroy;
Begin
  Log('destroy', llTrace);
  fudp.free;
  If ftcp.Connected Then Begin
    ftcp.Disconnect();
    While ftcp.Connected Do Begin
      ftcp.CallAction;
    End;
  End;
  ftcp.free;
  Inherited destroy;
End;

Procedure TNPoll.Restart;
Begin
  // So tun als hätten wir grad erst gestartet
  ftcp.Disconnect();
  While ftcp.Connected Do Begin
    ftcp.CallAction;
  End;
  { // Free TCP Component during restart
  ftcp.free;
  ftcp := Nil;
  ftcp := TLTcp.Create(Nil);
  ftcp.OnReceive := @OnTCPReceiveEvent;
  ftcp.OnError := @OnTCPErrorEvent;
  ftcp.OnDisconnect := @OnTCPDisconnect;
 // }
  fState := psWaitForConnection;
  logshow('waiting for connections...', llInfo);
End;

Procedure TNPoll.Execute;
Begin
  frunning := true;
  Log('Creating Connections.', llTrace);
  //  Try
  If Not fudp.Listen(fport) Then Begin
    logshow('Could not listen on udp', llWarning);
    fRunning := false;
  End
  Else Begin
    log('Start listening on port :' + inttostr(fPort), llTrace);
  End;
  //Except
  //  log('Unable to listen to port, maybe npush runs on same machine', llWarning);
  //  Try
  //    If ftcp.Connect('127.0.0.1', fPort) Then Begin
  //      frunning := true;
  //    End;
  //  Except
  //
  //  End;
  //End;
  logshow('waiting for connections...', llInfo);
  While frunning Do Begin
    fudp.CallAction;
    ftcp.CallAction;
    Case fState Of
      psWaitForConnection: Begin
          HandleWaitForConnection;
          If ForceIP <> '' Then Begin
            ConnectTCPToIP(ForceIP);
            frunning := true; // ConnectTCPToIP bricht ab, wenn es nicht verbinden kann, das soll hier natürlich nicht passieren.
          End;
        End;
      psChat: Begin
          HandleChat;
        End;
      psReceiveFiles: Begin
          HandleReceiveFiles;
        End;
    End;
    If fNeedRestart Then Begin
      fNeedRestart := false;
      Restart;
    End;
    sleep(1);
  End;
End;

Procedure TNPoll.OnUDPReceiveEvent(aSocket: TLSocket);
Var
  buffer: Array[0..BufferSize - 1] Of byte;
Begin
  If Not ftcp.Connected Then Begin
    // Npoll empfängt was, wir merken uns nur die IP, zum öffnen des TCP Kanals
    While aSocket.Get(buffer, BufferSize) <> 0 Do Begin
    End; // Gelesen werden muss aber sonst stimmt die PeerAddresse nicht, ka warum..
    ConnectTCPToIP(aSocket.PeerAddress);
  End;
End;

Procedure TNPoll.OnTCPReceiveEvent(aSocket: TLSocket);
Var
  Buffer: Array[0..BufferSize - 1] Of byte;
  i: integer;
  Cnt: int64;
  strLen: integer;
  (*
   * The Automatic Resend feature of Lnet is broken, so wie "fake" a automatik resend feature with this boolean.
   *)
  SomethingWasReceived: Boolean;
Begin
  Repeat
    SomethingWasReceived := false;
    Case fState Of
      psReceiveFiles: Begin
          Case fFileReceiveInfo.FileReceiveState Of
            frsReceiveFile: Begin
                Repeat
                  cnt := min(BufferSize, fFileReceiveInfo.FileSize - fFileReceiveInfo.Position);
                  If cnt > 0 Then Begin
                    cnt := aSocket.Get(buffer, cnt);
                    If cnt > 0 Then Begin
                      SomethingWasReceived := true;
                      fFileReceiveInfo.AktualFile.Write(buffer, cnt);
                      fFileReceiveInfo.Position := fFileReceiveInfo.Position + cnt;
                    End;
                  End;
                  If fFileReceiveInfo.Position >= fFileReceiveInfo.FileSize Then Begin
                    cnt := 0;
                    fFileReceiveInfo.AktualFile.free;
                    fFileReceiveInfo.AktualFile := Nil;
                    fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
                    SomethingWasReceived := true; // TODO: Macht das sinn ?
                  End;
                Until cnt = 0;
              End;
            frsWaitForNextFile: Begin
                cnt := aSocket.Get(buffer, 1); // Lesen des gesammten Headers
                If cnt > 0 Then SomethingWasReceived := true;
                If cnt <> 0 Then Begin
                  If Buffer[0] = 27 Then Begin
                    // Reguläres Ende
                    log('File transfer finished.', llTrace);
                    If StayOpen Then Begin
                      fNeedRestart := true;
                    End
                    Else Begin
                      frunning := false;
                    End;
                  End;
                  If (Buffer[0] = 1) Or (Buffer[0] = 9) Then Begin
                    // Umschalten auf Empfangen der Metadaten und auswerten dieser
                    fFileReceiveInfo.CheckMD5 := true;
                    fFileReceiveInfo.AppendData := Buffer[0] = 9;
                    fFileReceiveInfo.HeaderHeaderBytesPointer := 0;
                    fFileReceiveInfo.FileReceiveState := frsReceiveHeader;
                  End;
                  If (Buffer[0] = 2) Or (Buffer[0] = 10) Then Begin
                    // Umschalten auf Empfangen der Metadaten und auswerten dieser
                    fFileReceiveInfo.CheckMD5 := false;
                    fFileReceiveInfo.AppendData := Buffer[0] = 10;
                    fFileReceiveInfo.HeaderHeaderBytesPointer := 0;
                    fFileReceiveInfo.FileReceiveState := frsReceiveHeader;
                  End;
                End;
              End;
            frsReceiveHeader: Begin
                cnt := aSocket.Get(buffer, 28 - fFileReceiveInfo.HeaderHeaderBytesPointer); // Lesen des gesammten Headers
                If fFileReceiveInfo.HeaderHeaderBytesPointer = 28 Then SomethingWasReceived := true;
                If cnt > 0 Then SomethingWasReceived := true;
                setlength(fFileReceiveInfo.HeaderHeaderBytes, cnt + fFileReceiveInfo.HeaderHeaderBytesPointer);
                For i := 0 To cnt - 1 Do Begin
                  fFileReceiveInfo.HeaderHeaderBytes[fFileReceiveInfo.HeaderHeaderBytesPointer + i] := buffer[i];
                End;
                fFileReceiveInfo.HeaderHeaderBytesPointer := fFileReceiveInfo.HeaderHeaderBytesPointer + cnt;
                If fFileReceiveInfo.HeaderHeaderBytesPointer = 28 Then Begin
                  For i := 0 To 15 Do Begin
                    fFileReceiveInfo.md5[i] := fFileReceiveInfo.HeaderHeaderBytes[i];
                  End;
                  fFileReceiveInfo.Position := 0;
                  fFileReceiveInfo.FileSize := 0;
                  For i := 0 To 7 Do Begin
                    fFileReceiveInfo.FileSize := fFileReceiveInfo.FileSize Shl 8;
                    fFileReceiveInfo.FileSize := fFileReceiveInfo.FileSize Or fFileReceiveInfo.HeaderHeaderBytes[16 + i];
                  End;
                  strLen := (fFileReceiveInfo.HeaderHeaderBytes[24] Shl 24) Or (fFileReceiveInfo.HeaderHeaderBytes[25] Shl 16) Or (fFileReceiveInfo.HeaderHeaderBytes[26] Shl 8) Or (fFileReceiveInfo.HeaderHeaderBytes[27] Shl 0);
                  fFileReceiveInfo.HeaderBytesFilenameLen := strLen;
                  fFileReceiveInfo.Filename := '';
                  fFileReceiveInfo.FileReceiveState := frsReceiveHeaderFilename;
                  //OnTCPReceiveEvent(aSocket); // Keine Zeit verlieren, wir lesen gleich weiter
                End;
              End;
            frsReceiveHeaderFilename: Begin
                cnt := aSocket.Get(buffer, fFileReceiveInfo.HeaderBytesFilenameLen - length(fFileReceiveInfo.Filename));
                If cnt > 0 Then SomethingWasReceived := true;
                For i := 0 To cnt - 1 Do Begin
                  fFileReceiveInfo.Filename := fFileReceiveInfo.Filename + chr(buffer[i]);
                End;
                If length(fFileReceiveInfo.Filename) = fFileReceiveInfo.HeaderBytesFilenameLen Then Begin
                  HandleCheckIfFileNeedsToBeTransfered;
                End;
              End;
          End;
        End;
      psWaitForExecutionCommand: Begin
          cnt := aSocket.Get(buffer, 1);
          If cnt > 0 Then SomethingWasReceived := true;
          If cnt <> 0 Then Begin
            Case buffer[0] Of
              ord('0'): Begin // Nur ein Ping und wieder Beenden
                  aSocket.SendMessage('Ping');
                  logshow('Got ping from : ' + aSocket.PeerAddress, llInfo);
                  If StayOpen Then Begin
                    fNeedRestart := true;
                  End
                  Else Begin
                    frunning := false;
                  End;
                End;
              ord('1'): Begin // Umschalten in Chat Modus
                  fState := psChat;
                  logshow('Open chat mode, press ESC to exit.', llInfo);
                End;
              ord('2'): Begin
                  fState := psReceiveFiles;
                  log('Receive files', llTrace);
                  If assigned(fFileReceiveInfo.AktualFile) Then fFileReceiveInfo.AktualFile.free;
                  fFileReceiveInfo.AktualFile := Nil;
                  fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
                End
            Else Begin
                log('Unknown command : "' + chr(Buffer[0]) + '"', llWarning);
                frunning := false;
              End;
            End;
          End
          Else Begin
            frunning := false;
          End;
        End;
      psChat: Begin
          Repeat
            cnt := aSocket.Get(buffer, length(Buffer));
            If cnt > 0 Then SomethingWasReceived := true;
            For i := 0 To cnt - 1 Do Begin
              If Buffer[i] = 13 Then Begin
                WriteLn('');
              End
              Else Begin
                If buffer[i] = 27 Then Begin
                  frunning := false;
                End
                Else Begin
                  write(chr(buffer[i]));
                End;
              End;
            End;
          Until cnt = 0;
        End;
    End;
    (*
     * Wenn man wüsste wie ausgelesen werden kann ob im "Puffer" noch daten stehen wäre das natürlich besser,
     * aber so gehts auch ..
     *)
  Until Not SomethingWasReceived;
End;

Procedure TNPoll.OnTCPDisconnect(aSocket: TLSocket);
Begin
  // Todo : Evtl muss hier erkannt werden, welcher Socket sich Trennt, nicht das eine 2. Npush Verbindung was durcheinander bringt..
  If StayOpen Then Begin
    fNeedRestart := true;
  End
  Else Begin
    frunning := false;
  End;
End;

Procedure TNPoll.HandleWaitForConnection;
Begin
  If KeyPressed Then Begin
    If ReadKey = #27 Then Begin
      frunning := false;
    End;
  End;
End;

Procedure TNPoll.HandleChat;
Var
  k: Char;
Begin
  If KeyPressed Then Begin
    k := ReadKey;
    If k = #27 Then Begin // Abbruch durch Benutzer
      fRunning := false;
    End
    Else Begin
      If k = #13 Then Begin
        writeln('');
      End
      Else Begin
        write(k);
      End;
    End;
    ftcp.SendMessage(k);
  End;
End;

Procedure TNPoll.HandleReceiveFiles;
Var
  c: Char;
Begin
  If KeyPressed Then Begin
    c := ReadKey;
    If c = #27 Then Begin
      frunning := false;
    End;
    If c = 'i' Then Begin
      If fFileReceiveInfo.FileReceiveState = frsReceiveFile Then Begin
        writeln(format('%d kB from %d kB = %0.1f%%', [round(fFileReceiveInfo.Position / 1024), round(fFileReceiveInfo.FileSize / 1024), (fFileReceiveInfo.Position * 100) / fFileReceiveInfo.FileSize]));
      End;
    End;
  End;
End;

Procedure TNPoll.HandleCheckIfFileNeedsToBeTransfered;
  Procedure CommitDL(Filename: String);
  Var
    Buffer: Array[0..9] Of Byte;
    i64: int64;
    i: integer;
  Begin
    log('Commit download', llTrace);
    If Not RecursiveCreateDirUTF8(IncludeTrailingPathDelimiter(ExtractFilePath(Filename))) Then Begin
      // Der Pfad konnte nicht erstellt werden, wie sollen wir dann die Datei rein schreiben
      logshow('Error could not create Directorystructure for : ' + Filename, llFatal);
      ftcp.SendMessage('A');
      frunning := false;
      exit;
    End;
    If fFileReceiveInfo.FileSize = 0 Then Begin
      // Die Datei ist 0-Byte Groß
      fFileReceiveInfo.AktualFile := TFileStream.Create(UTF8ToSys(Filename), fmcreate Or fmOpenWrite);
      fFileReceiveInfo.AktualFile.free;
      fFileReceiveInfo.AktualFile := Nil;
      log('File already completed', llInfo);
      fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
      ftcp.SendMessage('N'); // Wir haben die Datei schon, die nächste bitte
      exit;
    End;
    fFileReceiveInfo.FileReceiveState := frsReceiveFile;
    If fFileReceiveInfo.AppendData And FileExistsUTF8(Filename) Then Begin
      If fFileReceiveInfo.AktualFile.Size = fFileReceiveInfo.FileSize Then Begin
        // Die Datei gibts schon Vollständig
        log('File already completed', llInfo);
        fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
        ftcp.SendMessage('N'); // Wir haben die Datei schon, die nächste bitte
      End
      Else Begin
        fFileReceiveInfo.AktualFile := TFileStream.Create(UTF8ToSys(Filename), fmOpenWrite);
        If fFileReceiveInfo.AktualFile.Size < fFileReceiveInfo.FileSize Then Begin
          // Es fehlt noch ein Stück der Datei
          fFileReceiveInfo.AktualFile.Position := fFileReceiveInfo.AktualFile.Size;
          fFileReceiveInfo.Position := fFileReceiveInfo.AktualFile.Size;
          i64 := fFileReceiveInfo.AktualFile.Size;
        End
        Else Begin
          // Die ZielDatei ist Größer als die gesendete, da müssen wir die Datei komplett hohlen
          i64 := 0;
        End;
        fFileReceiveInfo.Filename := Filename;
        buffer[0] := 8; // Steuerbefehl für Continue Large File
        For i := 0 To 7 Do Begin
          buffer[8 - i] := i64 And $FF;
          i64 := i64 Shr 8;
        End;
        If ftcp.Send(buffer, 9) <> 9 Then Begin
          fRunning := false;
          Raise Exception.Create('Verdammt FileSize nicht Vollständig gesendet.');
        End;
      End;
    End
    Else Begin
      fFileReceiveInfo.AktualFile := TFileStream.Create(UTF8ToSys(Filename), fmcreate Or fmOpenWrite);
      fFileReceiveInfo.Position := 0;
      fFileReceiveInfo.Filename := Filename;
      ftcp.SendMessage('Y');
    End;
  End;

Var
  s: String;
  md5: TMD5Digest;
Begin
  s := IncludeTrailingPathDelimiter(GetCurrentDirUTF8) + FixDelimeters(fFileReceiveInfo.Filename);
  logshow(FixDelimeters(fFileReceiveInfo.Filename), llInfo);
  If FileExistsUTF8(s) And (fFileReceiveInfo.CheckMD5) Then Begin
    log('File already exists, check MD5', llTrace);
    md5 := MD5File(s);
    If MD5Match(md5, fFileReceiveInfo.md5) Then Begin
      log('MD5 OK, no need to transfer.', llTrace);
      fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
      ftcp.SendMessage('N'); // Wir haben die Datei schon, die nächste bitte
    End
    Else Begin
      // Wir haben die Datei zwar, aber sie ist nicht die gleiche
      CommitDL(s);
    End;
  End
  Else Begin
    // Die Datei gibt es nicht, also brauchen wir sie auf Jeden Fall
    CommitDL(s);
  End;
End;

Procedure TNPoll.ConnectTCPToIP(IP_Address: String);
Begin
  If Not ftcp.Connected Then Begin
    Log('Connecting TCP to: ' + IP_Address, llTrace);
    If ftcp.Connect(IP_Address, fPort) Then Begin
      log('Successfully connected TCP', llTrace);
      fState := psWaitForExecutionCommand;
    End
    Else Begin
      log('Unable to connect via TCP', llTrace);
      frunning := false;
    End;
  End;
End;

Procedure TNPoll.OnUDPErrorEvent(Const msg: String; aSocket: TLSocket);
Begin
  If assigned(aSocket) Then Begin
    logshow('UDP: ' + aSocket.PeerAddress + ': ' + msg, llWarning);
  End
  Else Begin
    logshow('UDP: ' + msg, llWarning);
  End;
  fRunning := false;
End;

Procedure TNPoll.OnTCPErrorEvent(Const msg: String; aSocket: TLSocket);
Begin
  If assigned(aSocket) Then Begin
    logshow('TCP: ' + aSocket.PeerAddress + ': ' + msg, llWarning);
  End
  Else Begin
    logshow('TCP: ' + msg, llWarning);
  End;
  fRunning := false;
End;

End.

