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
    fExitStatus: integer;
    fWaitStart: QWord; // Seit wann auf ein npush gewartet wird (für Timeout)
    fSessionCount: integer; // Anzahl abgeschlossener Übertragungen (bei -s mehrere)
    fSessionDone: Boolean; // npush hat das reguläre Ende (27) gesendet
    // Statistik der aktuellen Übertragung
    fStatFiles: integer;
    fStatSkipped: integer;
    fStatErrors: integer;
    fStatBytes: int64;
    fStatStart: QWord;
    // Fortschrittsanzeige der aktuellen Datei
    fFileStart: QWord;
    fFileStartPosition: int64;
    fLastProgress: QWord;
    fProgressVisible: Boolean;
    fProgressLen: integer;
    Procedure Restart; // Tut so als wäre die App neu gestartet worden
    Procedure SetExitStatus(Value: integer);
    Procedure ShowProgress(Final: Boolean);
    Procedure ShowSummary(Success: Boolean);
    Procedure FileStarted;
    Procedure FileFinished;
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
    Quiet: Boolean; // Keine automatische Fortschrittsanzeige
    NoOverwrite: Boolean; // Vorhandene Dateien nicht überschreiben
    Timeout: integer; // Sekunden die auf ein npush gewartet wird, 0 = unbegrenzt
    Constructor create(Port: integer);
    Destructor destroy; override;
    Procedure Execute;
    Property ExitStatus: integer read fExitStatus;
  End;

Implementation

Uses ulogger, crt, math, lazutf8, LazFileUtils;

Const
  MaxFilenameLen = 32767; // Mehr kann auch Windows mit "\\?\" Prefix nicht

Function FixDelimeters(value: String): String;
Begin
{$IFDEF UNIX}
  result := StringReplace(value, '\', '/', [rfReplaceAll]);
{$ELSE}
  result := StringReplace(value, '/', '\', [rfReplaceAll]);
{$ENDIF}
End;

Function FormatSize(Value: int64): String;
Begin
  If Value < 1024 Then Begin
    result := inttostr(Value) + ' B';
  End
  Else If Value < 1024 * 1024 Then Begin
    result := format('%0.1f KB', [Value / 1024]);
  End
  Else If Value < 1024 * 1024 * 1024 Then Begin
    result := format('%0.1f MB', [Value / (1024 * 1024)]);
  End
  Else Begin
    result := format('%0.2f GB', [Value / (1024 * 1024 * 1024)]);
  End;
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
  Quiet := false;
  NoOverwrite := false;
  Timeout := 0;
  fExitStatus := ecOK;
  fSessionCount := 0;
  fSessionDone := false;
  fProgressVisible := false;
  fProgressLen := 0;
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
  If assigned(fFileReceiveInfo.AktualFile) Then fFileReceiveInfo.AktualFile.free;
  fFileReceiveInfo.AktualFile := Nil;
  fWaitStart := GetTickCount64;
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
    SetExitStatus(ecError);
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
  fWaitStart := GetTickCount64;
  While frunning Do Begin
    fudp.CallAction;
    ftcp.CallAction;
    Case fState Of
      psWaitForConnection: Begin
          HandleWaitForConnection;
          If frunning And (ForceIP <> '') Then Begin // frunning = false -> Benutzer hat ESC gedrückt
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
                      fStatBytes := fStatBytes + cnt;
                    End;
                  End;
                  If fFileReceiveInfo.Position >= fFileReceiveInfo.FileSize Then Begin
                    cnt := 0;
                    FileFinished;
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
                    fSessionDone := true;
                    inc(fSessionCount);
                    ShowSummary(fStatErrors = 0);
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
                  If (strLen <= 0) Or (strLen > MaxFilenameLen) Then Begin
                    // Ungültige Länge, die Gegenstelle ist kein npush oder spricht ein anderes Protokoll
                    logshow('Error invalid filename length : ' + inttostr(strLen), llFatal);
                    SetExitStatus(ecError);
                    ftcp.SendMessage('A');
                    frunning := false;
                    exit;
                  End;
                  fFileReceiveInfo.HeaderBytesFilenameLen := strLen;
                  fFileReceiveInfo.Filename := '';
                  fFileReceiveInfo.FileReceiveState := frsReceiveHeaderFilename;
                  //OnTCPReceiveEvent(aSocket); // Keine Zeit verlieren, wir lesen gleich weiter
                End;
              End;
            frsReceiveHeaderFilename: Begin
                cnt := aSocket.Get(buffer, min(BufferSize, fFileReceiveInfo.HeaderBytesFilenameLen - length(fFileReceiveInfo.Filename)));
                If cnt > 0 Then SomethingWasReceived := true;
                For i := 0 To cnt - 1 Do Begin
                  fFileReceiveInfo.Filename := fFileReceiveInfo.Filename + chr(buffer[i]);
                End;
                If length(fFileReceiveInfo.Filename) = fFileReceiveInfo.HeaderBytesFilenameLen Then Begin
                  HandleCheckIfFileNeedsToBeTransfered;
                  If Not frunning Then exit; // Abbruch (z.B. ungültiger Dateiname), sonst würde hier mit Länge 0 weiter gelesen
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
                  logshow('Receive files from : ' + aSocket.PeerAddress, llInfo);
                  If assigned(fFileReceiveInfo.AktualFile) Then fFileReceiveInfo.AktualFile.free;
                  fFileReceiveInfo.AktualFile := Nil;
                  fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
                  fSessionDone := false;
                  fStatFiles := 0;
                  fStatSkipped := 0;
                  fStatErrors := 0;
                  fStatBytes := 0;
                  fStatStart := GetTickCount64;
                End
            Else Begin
                log('Unknown command : "' + chr(Buffer[0]) + '"', llWarning);
                SetExitStatus(ecError);
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
  If (fState = psReceiveFiles) And Not fSessionDone Then Begin
    // npush ist mitten in der Übertragung weg, die aktuelle Datei ist unvollständig
    If assigned(fFileReceiveInfo.AktualFile) Then Begin
      fFileReceiveInfo.AktualFile.free;
      fFileReceiveInfo.AktualFile := Nil;
      If fProgressVisible Then writeln('');
      fProgressVisible := false;
      logshow('Incomplete file (continue with npush -a) : ' + fFileReceiveInfo.Filename, llWarning);
    End;
    logshow('Connection to npush lost.', llWarning);
    fSessionDone := true;
    ShowSummary(false);
  End;
  If StayOpen Then Begin
    fNeedRestart := true;
  End
  Else Begin
    frunning := false;
  End;
End;

Procedure TNPoll.HandleWaitForConnection;
Begin
  If (Timeout > 0) And (GetTickCount64 - fWaitStart > QWord(Timeout) * 1000) Then Begin
    If fSessionCount = 0 Then Begin
      logshow('No npush found within ' + inttostr(Timeout) + ' s.', llWarning);
      SetExitStatus(ecNoPartner);
    End;
    frunning := false;
    exit;
  End;
  If KeyPressed Then Begin
    If ReadKey = #27 Then Begin
      // Bei -s ist ESC nach einer Übertragung das reguläre Ende
      If fSessionCount = 0 Then SetExitStatus(ecUserAbort);
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
      If fProgressVisible Then writeln('');
      fProgressVisible := false;
      SetExitStatus(ecUserAbort);
      frunning := false;
    End;
    If c = 'i' Then Begin // Fortschritt auch bei -q auf Anforderung
      If fFileReceiveInfo.FileReceiveState = frsReceiveFile Then Begin
        ShowProgress(false);
      End;
    End;
  End;
  If frunning And (Not Quiet) And (fFileReceiveInfo.FileReceiveState = frsReceiveFile) And
    (GetTickCount64 - fLastProgress >= 500) Then Begin
    ShowProgress(false);
  End;
End;

Procedure TNPoll.SetExitStatus(Value: integer);
Begin
  // Der erste Grund gewinnt, ein späteres ESC soll einen Fehler nicht verdecken
  If fExitStatus = ecOK Then fExitStatus := Value;
End;

Procedure TNPoll.ShowProgress(Final: Boolean);
Var
  s, eta: String;
  secs, rate: Double;
  pct: Double;
Begin
  fLastProgress := GetTickCount64;
  secs := (fLastProgress - fFileStart) / 1000;
  rate := 0;
  If secs > 0 Then rate := (fFileReceiveInfo.Position - fFileStartPosition) / secs;
  pct := 100;
  If fFileReceiveInfo.FileSize > 0 Then pct := fFileReceiveInfo.Position * 100 / fFileReceiveInfo.FileSize;
  If Final Then Begin
    eta := format('%0.1f s', [secs]);
  End
  Else If rate > 0 Then Begin
    eta := format('%d s left', [round((fFileReceiveInfo.FileSize - fFileReceiveInfo.Position) / rate)]);
  End
  Else Begin
    eta := '';
  End;
  s := format('  %5.1f%%  %s / %s  %s/s  %s', [pct, FormatSize(fFileReceiveInfo.Position), FormatSize(fFileReceiveInfo.FileSize), FormatSize(round(rate)), eta]);
  // Mit #13 wird die Zeile überschrieben, Leerzeichen löschen die Reste einer längeren Zeile
  write(#13 + s + StringOfChar(' ', max(0, fProgressLen - length(s))));
  fProgressLen := length(s);
  fProgressVisible := true;
  If Final Then Begin
    writeln('');
    fProgressVisible := false;
    fProgressLen := 0;
  End;
End;

Procedure TNPoll.ShowSummary(Success: Boolean);
Var
  secs: Double;
  s: String;
Begin
  secs := (GetTickCount64 - fStatStart) / 1000;
  s := format('%d file(s) received, %d skipped, %d failed, %s in %0.1f s', [fStatFiles, fStatSkipped, fStatErrors, FormatSize(fStatBytes), secs]);
  If secs > 0 Then s := s + ' (' + FormatSize(round(fStatBytes / secs)) + '/s)';
  If Success Then Begin
    logshow('Done: ' + s, llInfo);
  End
  Else Begin
    logshow('Aborted: ' + s, llWarning);
    SetExitStatus(ecError);
  End;
End;

Procedure TNPoll.FileStarted;
Begin
  fFileStart := GetTickCount64;
  fLastProgress := fFileStart;
  fFileStartPosition := fFileReceiveInfo.Position;
End;

(*
 * Die aktuelle Datei ist vollständig empfangen, bei -md5 wird sie gegen die
 * Prüfsumme von npush geprüft. Eine falsche Datei wird gelöscht, damit sie
 * beim nächsten Mal komplett neu übertragen wird (auch mit -a).
 *)

Procedure TNPoll.FileFinished;
Var
  md5: TMD5Digest;
Begin
  fFileReceiveInfo.AktualFile.free;
  fFileReceiveInfo.AktualFile := Nil;
  If fProgressVisible Then ShowProgress(true);
  If fFileReceiveInfo.CheckMD5 Then Begin
    md5 := MD5File(fFileReceiveInfo.Filename);
    If Not MD5Match(md5, fFileReceiveInfo.md5) Then Begin
      logshow('MD5 mismatch, file deleted : ' + fFileReceiveInfo.Filename, llWarning);
      DeleteFileUTF8(fFileReceiveInfo.Filename);
      inc(fStatErrors);
      SetExitStatus(ecError);
      exit;
    End;
    log('MD5 verified : ' + fFileReceiveInfo.Filename, llTrace);
  End;
  inc(fStatFiles);
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
      SetExitStatus(ecError);
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
      inc(fStatFiles);
      fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
      ftcp.SendMessage('N'); // Wir haben die Datei schon, die nächste bitte
      exit;
    End;
    fFileReceiveInfo.FileReceiveState := frsReceiveFile;
    If fFileReceiveInfo.AppendData And FileExistsUTF8(Filename) Then Begin
      fFileReceiveInfo.AktualFile := TFileStream.Create(UTF8ToSys(Filename), fmOpenWrite);
      // Bei -md5 sind wir nur hier, wenn die MD5 nicht passt, eine gleich große Datei ist dann
      // nicht vollständig sondern anders und muss komplett neu geholt werden
      If (fFileReceiveInfo.AktualFile.Size = fFileReceiveInfo.FileSize) And (Not fFileReceiveInfo.CheckMD5) Then Begin
        // Die Datei gibts schon Vollständig
        fFileReceiveInfo.AktualFile.free;
        fFileReceiveInfo.AktualFile := Nil;
        log('File already completed', llInfo);
        inc(fStatSkipped);
        fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
        ftcp.SendMessage('N'); // Wir haben die Datei schon, die nächste bitte
      End
      Else Begin
        If fFileReceiveInfo.AktualFile.Size < fFileReceiveInfo.FileSize Then Begin
          // Es fehlt noch ein Stück der Datei
          fFileReceiveInfo.AktualFile.Position := fFileReceiveInfo.AktualFile.Size;
          fFileReceiveInfo.Position := fFileReceiveInfo.AktualFile.Size;
          i64 := fFileReceiveInfo.AktualFile.Size;
        End
        Else Begin
          // Die ZielDatei ist Größer als die gesendete, da müssen wir die Datei komplett hohlen
          // und den alten Rest abschneiden, sonst bleibt er am Ende stehen
          fFileReceiveInfo.AktualFile.Size := 0;
          fFileReceiveInfo.Position := 0;
          i64 := 0;
        End;
        fFileReceiveInfo.Filename := Filename;
        FileStarted;
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
      FileStarted;
      ftcp.SendMessage('Y');
    End;
  End;

Var
  s, Base: String;
  md5: TMD5Digest;
Begin
  Base := IncludeTrailingPathDelimiter(ExpandFileNameUTF8(GetCurrentDirUTF8));
  s := ExpandFileNameUTF8(Base + FixDelimeters(fFileReceiveInfo.Filename));
  logshow(FixDelimeters(fFileReceiveInfo.Filename), llInfo);
  If (pos(Base, s) <> 1) Or (length(s) <= length(Base)) Then Begin
    // Der Dateiname zeigt via ".." aus dem aktuellen Verzeichnis heraus, das darf nicht sein
    logshow('Error filename points outside of the current directory : ' + fFileReceiveInfo.Filename, llFatal);
    SetExitStatus(ecError);
    ftcp.SendMessage('A');
    frunning := false;
    exit;
  End;
  If NoOverwrite And FileExistsUTF8(s) Then Begin
    logshow('File exists, skipped (-n).', llInfo);
    inc(fStatSkipped);
    fFileReceiveInfo.FileReceiveState := frsWaitForNextFile;
    ftcp.SendMessage('N'); // Nicht überschreiben, die nächste bitte
    exit;
  End;
  If FileExistsUTF8(s) And (fFileReceiveInfo.CheckMD5) Then Begin
    log('File already exists, check MD5', llTrace);
    md5 := MD5File(s);
    If MD5Match(md5, fFileReceiveInfo.md5) Then Begin
      log('MD5 OK, no need to transfer.', llTrace);
      inc(fStatSkipped);
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
  SetExitStatus(ecError);
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
  // Nach dem regulären Ende (27, Ping) trennt npush hart, das ist kein Fehler mehr
  If fRunning And (Not fNeedRestart) And Not ((fState = psReceiveFiles) And fSessionDone) Then Begin
    SetExitStatus(ecError);
  End;
  fRunning := false;
End;

End.

