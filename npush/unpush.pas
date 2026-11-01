(******************************************************************************)
(*                                                                            *)
(* Author      : Uwe Schächterle (Corpsman)                                   *)
(*                                                                            *)
(* This file is part of ntools/npush                                          *)
(*                                                                            *)
(*  See the file license.md, located under:                                   *)
(*  https://github.com/PascalCorpsman/Software_Licenses/blob/main/license.md  *)
(*  for details about the license.                                            *)
(*                                                                            *)
(*               It is not allowed to change or remove this text from any     *)
(*               source file of the project.                                  *)
(*                                                                            *)
(******************************************************************************)
Unit unpush;

{$MODE objfpc}{$H+}

Interface

Uses
  Classes, SysUtils, lnet;

{$I ../ntools.inc}

Type

  TPushState = (
    psWaitForConnection, // Warten darauf das nPoll sich via TCP verbindet
    psChat, // Chat Modus
    psPing, // Warten darauf dass Npoll mit einem "Ping" antwortet und dann Beenden
    psTransferFiles // Arbeitet die Liste der Erstellten Dateien ab und dann Beenden
    );

  TPushMode = (
    pmPing, // Keine Dateien angegeben, nur ein Verbindungstest
    pmChat, // Option -c
    pmFiles // Dateien übertragen
    );

  TFileSendState = (
    fssReadyForNextFile, // Alles Aktuelle ist Abgearbeitet, Starten mit der Nächste zu übertragenden Datei
    fssWaitForCRCResponse, // Anfrage bei Npoll ob die Datei gesendert werden soll
    fssWaitForResumeOffset, // Npoll will fortsetzen, Empfangen der 8 Byte Position (kann in Teilen kommen)
    fssWaitForHeaderTransfer, // Warten bis wir den Header vollständig übertragen haben
    fssFileTransfering // Die Aktuelle Datei wird übertragen
    );

  TFileSendInfo = Record
    FileSendState: TFileSendState;
    AktualFile: TFileStream;
    Position: int64;
    FileSize: int64;
    HeaderBytes: Array Of byte;
    HeaderBytePointer: Integer;
    ResumeBytes: Array[0..7] Of byte;
    ResumeBytesPointer: Integer;
  End;

  { TNPush }

  TNPush = Class
  private
    fudp: TLUdp;
    ftcp: TLTcp;
    fClient: TLSocket; // Die Verbindung zu dem npoll, das gerade bedient wird
    fPending: TList; // npoll's die sich verbunden haben, während ein anderes bedient wurde
    fPort: Word;
    fState: TPushState;
    fMode: TPushMode;
    fRunning: Boolean;
    fExitStatus: integer;
    fHandleWaitForConnectionCounter: integer;
    fWaitStart: QWord; // Seit wann auf ein npoll gewartet wird (für Timeout)
    fSessionCount: integer; // Anzahl bisher bedienter npoll's
    fAllSourceFiles: TStringList; // Werden einmalig beim Start ermittelt und für jede Sitzung kopiert
    fAllDestFiles: TStringList;
    fSourceFilelist: TSTringlist;
    fDestFileList: TSTringlist;
    fFileSendInfo: TFileSendInfo;
    // Statistik der aktuellen Sitzung
    fStatFiles: integer;
    fStatSkipped: integer;
    fStatBytes: int64;
    fStatStart: QWord;
    // Fortschrittsanzeige der aktuellen Datei
    fFileStart: QWord;
    fFileStartPosition: int64;
    fLastProgress: QWord;
    fProgressVisible: Boolean;
    fProgressLen: integer;
    Procedure OnUDPErrorEvent(Const msg: String; aSocket: TLSocket);
    Procedure OnUDPDisconnectEvent(aSocket: TLSocket);
    Procedure OnUDPReceiveEvent(aSocket: TLSocket);

    Procedure OnTCPErrorEvent(Const msg: String; aSocket: TLSocket);
    Procedure OnTCPReceiveEvent(aSocket: TLSocket);
    Procedure OnTCPDisconnectEvent(aSocket: TLSocket);
    Procedure OnTCPCanSendEvent(aSocket: TLSocket);
    Procedure OnTCPAcceptEvent(aSocket: TLSocket);

    Function CollectFiles: Boolean;
    Procedure StartSession(aSocket: TLSocket);
    Procedure EndSession(Success: Boolean);
    Procedure SetExitStatus(Value: integer);
    Procedure ShowProgress(Final: Boolean);
    Procedure NextFile;
    Procedure FileStarted;

    Procedure HandleWaitForConnection;
    Procedure HandleChat;
    Procedure HandlePing;
    Procedure HandleTransferFiles;
  public
    AppendData: Boolean;
    CheckMD5: Boolean;
    Quiet: Boolean; // Keine automatische Fortschrittsanzeige
    MaxSessions: integer; // Anzahl npoll's die bedient werden, 0 = bis ESC
    Timeout: integer; // Sekunden die auf ein npoll gewartet wird, 0 = unbegrenzt
    UDPBroadCastIP: String;
    Constructor create(Port: integer);
    Destructor destroy; override;
    Procedure Execute;
    Property ExitStatus: integer read fExitStatus;
  End;

Implementation

Uses ulogger, crt, FileUtil, LazUTF8, LazFileUtils, math, md5, uip;

Const
  Welcome_Message = 'Hello';

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

{ TNPush }

Constructor TNPush.create(Port: integer);
Begin
  Inherited create;
  Log('npush ver. ' + Version, llTrace);
  Log('npush ver. ' + Version, llInfo);
  UDPBroadCastIP := LADDR_BR;
  fPort := Port;
  CheckMD5 := false;
  AppendData := false;
  Quiet := false;
  MaxSessions := 1;
  Timeout := 0;
  fExitStatus := ecOK;
  fudp := TLUdp.Create(Nil);
  fudp.OnDisconnect := @OnudpDisconnectEvent;
  fudp.OnError := @OnudpErrorEvent;
  fudp.OnReceive := @OnUDPReceiveEvent;

  ftcp := TLTcp.Create(Nil);
  ftcp.ReuseAddress := true; // Damit sofort wieder gestartet werden kann ohne auf einen Timeout zu warten
  ftcp.OnReceive := @OnTCPReceiveEvent;
  ftcp.OnCanSend := @OnTCPCanSendEvent;
  ftcp.OnDisconnect := @OnTCPDisconnectEvent;
  ftcp.OnError := @OnTCPErrorEvent;
  ftcp.OnAccept := @OnTCPAcceptEvent;

  fState := psWaitForConnection;
  fMode := pmPing;
  fClient := Nil;
  fPending := TList.Create;
  fHandleWaitForConnectionCounter := 0;
  fSessionCount := 0;
  fAllSourceFiles := TStringList.Create;
  fAllDestFiles := TStringList.Create;
  fSourceFilelist := TStringList.Create;
  fDestFileList := TStringList.Create;
  fProgressVisible := false;
  fProgressLen := 0;
End;

Destructor TNPush.destroy;
Begin
  Log('destroy', llTrace);
  fSourceFilelist.free;
  fDestFileList.free;
  fAllSourceFiles.free;
  fAllDestFiles.free;
  If Assigned(fFileSendInfo.AktualFile) Then fFileSendInfo.AktualFile.Free;
  fFileSendInfo.AktualFile := Nil;
  fudp.free;
  If ftcp.Connected Then Begin
    ftcp.Disconnect(); // Force oder nicht Force, das ist hier die Frage
    While ftcp.Connected Do Begin
      ftcp.CallAction;
    End;
  End;
  ftcp.free;
  fPending.free;
  Inherited destroy;
End;

Procedure TNPush.SetExitStatus(Value: integer);
Begin
  // Der erste Grund gewinnt, ein späteres ESC soll einen Fehler nicht verdecken
  If fExitStatus = ecOK Then fExitStatus := Value;
End;

(*
 * Wertet die Übergabeparameter aus und erstellt die Liste der zu sendenden Dateien.
 * Wird einmalig beim Start aufgerufen, so werden Tippfehler sofort gemeldet und nicht
 * erst wenn sich ein npoll verbunden hat.
 *)

Function TNPush.CollectFiles: Boolean;
Var
  Cwd: String;

  Procedure AddFiles(Const sl: TStringList; CutLen: integer);
  Var
    j: integer;
  Begin
    For j := 0 To sl.Count - 1 Do Begin
      fAllSourceFiles.Add(sl[j]);
      fAllDestFiles.Add(copy(sl[j], CutLen + 1, length(sl[j])));
    End;
    sl.free;
  End;

Var
  i: integer;
  p, s: String;
  FileArgs: integer;
Begin
  result := true;
  Cwd := GetCurrentDirUTF8;
  FileArgs := 0;
  i := 0;
  While i < ParamCount Do Begin
    inc(i);
    p := trim(ParamStrUTF8(i)); // trim, da die Parameter mit einem crt terminiert sein können
    If (lowercase(p) = '-l') Or (lowercase(p) = '-p') Or (lowercase(p) = '-i') Or
      (lowercase(p) = '-t') Or (lowercase(p) = '-m') Then Begin // Optionen mit Wert überspringen
      inc(i);
      Continue;
    End;
    If (lowercase(p) = '-md5') Or (lowercase(p) = '-a') Or (lowercase(p) = '-q') Then Continue;
    If lowercase(p) = '-c' Then Begin
      fMode := pmChat;
      Continue;
    End;
    If p = '' Then Continue;
    inc(FileArgs);
    If (p = '*.*') Then Begin // Alle Lokalen Dateien
      AddFiles(FindAllFiles(Cwd, '', false), length(Cwd));
      Continue;
    End;
    If (p = '*') Then Begin // Alle Dateien und Unterordner
      AddFiles(FindAllFiles(Cwd, '', true), length(Cwd));
      Continue;
    End;
    If pos('*.', p) = 1 Then Begin // Alle Dateien der Art *.xyz [;*.abc]
      AddFiles(FindAllFiles(Cwd, p, false), length(Cwd));
      Continue;
    End;
    If DirectoryExistsUTF8(p) Then Begin
      If (pos(Cwd, p) = 1) Then Begin
        AddFiles(FindAllFiles(p, '', true), length(Cwd));
      End
      Else If DirectoryExistsUTF8(IncludeTrailingPathDelimiter(Cwd) + p) Then Begin
        AddFiles(FindAllFiles(IncludeTrailingPathDelimiter(Cwd) + p, '', true), length(Cwd));
      End
      Else Begin
        // Es wurde ein Verzeichnis Übergeben wir schneiden den Namen aus und übergeben alles drunter
        s := ExcludeTrailingPathDelimiter(p);
        s := IncludeTrailingPathDelimiter(ExtractFilePath(s));
        AddFiles(FindAllFiles(p, '', true), length(s) - 1);
      End;
      Continue;
    End;
    If FileExistsUTF8(p) Then Begin
      fAllSourceFiles.Add(p);
      fAllDestFiles.Add(ExtractFileName(p));
      Continue;
    End;
    If pos('-', p) = 1 Then Begin
      LogShow('Unknown option: ' + p + ', see npush -h', llWarning);
    End
    Else Begin
      LogShow('File or directory not found: ' + p, llWarning);
    End;
    result := false;
  End;
  If Not result Then exit;
  If fMode = pmChat Then exit;
  If FileArgs = 0 Then Begin
    fMode := pmPing;
  End
  Else Begin
    If fAllSourceFiles.Count = 0 Then Begin
      LogShow('No files found to send.', llWarning);
      result := false;
      exit;
    End;
    fMode := pmFiles;
  End;
End;

Procedure TNPush.Execute;
Begin
  If Not CollectFiles Then Begin
    SetExitStatus(ecError);
    exit;
  End;
  If fMode = pmFiles Then Begin
    Log(format('%d file(s) to send', [fAllSourceFiles.Count]), llInfo);
  End;
  // 1.1 Alle Server Starten
  logger.Log('Creating Connections.', llTrace);
  frunning := true;
  If Not fudp.Connect('' {localhost}, fPort) Then Begin // Die Windows Version funktioniert so am besten ...
    LogShow('Could not connect to udp, abort now.', llWarning);
    frunning := false;
  End
  Else Begin
    log('Start udp listen on port : ' + inttostr(fPort), llTrace);
  End;
  If Not ftcp.listen(fPort) Then Begin
    LogShow('Could not listen on tcp, abort now.', llWarning);
    frunning := false;
  End
  Else Begin
    log('Start tcp listen on port : ' + inttostr(fPort), llTrace);
  End;
  // 2. Endlosschleife bis alles erledigt ist, oder der Benutzer ESC Tippt
  If frunning Then Begin
    LogShow('scanning for connections...', llinfo);
    fudp.SendMessage(Welcome_Message, LADDR_LO); // Wir senden zu allererst ein Packet an uns selbst, sollte Npoll zuvällig auf der Eigenen IP laufen
  End
  Else Begin
    SetExitStatus(ecError);
  End;
  fWaitStart := GetTickCount64;
  While frunning Do Begin
    ftcp.CallAction;
    fudp.CallAction;
    Case fState Of
      psWaitForConnection: Begin
          HandleWaitForConnection;
        End;
      psChat: Begin
          HandleChat;
        End;
      psPing: Begin
          HandlePing;
        End;
      psTransferFiles: Begin
          HandleTransferFiles;
        End;
    End;
    sleep(1); // Prevent 100% CPU-Load
  End;
End;

Procedure TNPush.HandleWaitForConnection;
Var
  N: TNetworkAdapterList;
  i: Integer;
  bip: String;
Begin
  If (Timeout > 0) And (GetTickCount64 - fWaitStart > QWord(Timeout) * 1000) Then Begin
    If fSessionCount = 0 Then Begin
      LogShow('No npoll found within ' + inttostr(Timeout) + ' s.', llWarning);
      SetExitStatus(ecNoPartner);
    End;
    fRunning := false;
    exit;
  End;
  inc(fHandleWaitForConnectionCounter);
  If fHandleWaitForConnectionCounter Mod 250 = 0 Then Begin
    fHandleWaitForConnectionCounter := 0;
    If UDPBroadCastIP <> LADDR_BR Then Begin // Der User hat eine Bestimmte IP vorgegeben dann versuchen wir es auch nur dort
      logger.Log('Ping to : ' + UDPBroadCastIP, llTrace);
      fudp.SendMessage(Welcome_Message, UDPBroadCastIP);
    End
    Else Begin
      n := GetLocalIPs();
      For i := 0 To high(n) Do Begin
        Try
          bip := CalculateBroadCastAddressFromAddress(n[i].IpAddress, n[i].SubnetMask);
        Except
          On e: Exception Do Begin
            // Ein Adapter mit unbrauchbaren Daten darf nicht alle anderen verhindern
            logger.Log('Skip adapter ' + n[i].AdapterName + ': ' + e.Message, llWarning);
            Continue;
          End;
        End;
        logger.Log('Ping to : ' + bip, llTrace);
        fudp.SendMessage(Welcome_Message, bip);
      End;
    End;
  End;
  If KeyPressed Then Begin // Abbruch durch Benutzer
    If ReadKey = #27 Then Begin
      // Wurde schon mindestens ein npoll bedient, ist ESC das reguläre Ende (-m 0)
      If fSessionCount = 0 Then SetExitStatus(ecUserAbort);
      fRunning := false;
    End;
  End;
End;

Procedure TNPush.HandleChat;
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
    If assigned(fClient) Then fClient.SendMessage(k);
  End;
End;

Procedure TNPush.HandlePing;
Begin
  If KeyPressed Then Begin // Abbruch durch Benutzer
    If ReadKey = #27 Then Begin
      SetExitStatus(ecUserAbort);
      fRunning := false;
    End;
  End;
End;

Procedure TNPush.HandleTransferFiles;
Var
  c: Char;
Begin
  If KeyPressed Then Begin // Abbruch durch Benutzer
    c := ReadKey;
    If c = #27 Then Begin
      If fProgressVisible Then writeln('');
      SetExitStatus(ecUserAbort);
      fRunning := false;
    End;
    If c = 'i' Then Begin // Fortschritt auch bei -q auf Anforderung
      If fFileSendInfo.FileSendState = fssFileTransfering Then Begin
        ShowProgress(false);
      End;
    End;
  End;
  If fRunning Then Begin
    If (Not Quiet) And (fFileSendInfo.FileSendState = fssFileTransfering) And
      (GetTickCount64 - fLastProgress >= 500) Then Begin
      ShowProgress(false);
    End;
    Case fFileSendInfo.FileSendState Of
      fssReadyForNextFile: Begin
          If fSourceFilelist.Count = 0 Then Begin
            //Fertig, kontrolliert runter fahren
            fClient.SendMessage(#27);
            EndSession(true);
          End
          Else Begin
            NextFile;
          End;
        End;
    End;
  End;
End;

Procedure TNPush.ShowProgress(Final: Boolean);
Var
  s, eta: String;
  secs, rate: Double;
  pct: Double;
Begin
  fLastProgress := GetTickCount64;
  secs := (fLastProgress - fFileStart) / 1000;
  rate := 0;
  If secs > 0 Then rate := (fFileSendInfo.Position - fFileStartPosition) / secs;
  pct := 100;
  If fFileSendInfo.FileSize > 0 Then pct := fFileSendInfo.Position * 100 / fFileSendInfo.FileSize;
  If Final Then Begin
    eta := format('%0.1f s', [secs]);
  End
  Else If rate > 0 Then Begin
    eta := format('%d s left', [round((fFileSendInfo.FileSize - fFileSendInfo.Position) / rate)]);
  End
  Else Begin
    eta := '';
  End;
  s := format('  %5.1f%%  %s / %s  %s/s  %s', [pct, FormatSize(fFileSendInfo.Position), FormatSize(fFileSendInfo.FileSize), FormatSize(round(rate)), eta]);
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

Procedure TNPush.FileStarted;
Begin
  fFileStart := GetTickCount64;
  fLastProgress := fFileStart;
  fFileStartPosition := fFileSendInfo.Position;
  fFileSendInfo.FileSendState := fssFileTransfering;
End;

Procedure TNPush.StartSession(aSocket: TLSocket);
Begin
  fClient := aSocket;
  Case fMode Of
    pmChat: Begin
        fState := psChat;
        Logshow('Open chat mode, press ESC to exit.', llInfo);
        aSocket.SendMessage('1'); // Steuercode 1 => Chat Modus
      End;
    pmPing: Begin
        Log('Sent a ping', llInfo);
        fstate := psPing;
        aSocket.SendMessage('0'); // Steuercode 0 => Ping, dann Beenden
      End;
    pmFiles: Begin
        LogShow('Send files to : ' + aSocket.PeerAddress, llInfo);
        fSourceFilelist.Assign(fAllSourceFiles);
        fDestFileList.Assign(fAllDestFiles);
        fStatFiles := 0;
        fStatSkipped := 0;
        fStatBytes := 0;
        fStatStart := GetTickCount64;
        fFileSendInfo.FileSendState := fssReadyForNextFile;
        fState := psTransferFiles;
        aSocket.SendMessage('2'); // Steuercode 2 => Sende eine Beliebige Anzahl an Dateien
      End;
  End;
End;

Procedure TNPush.EndSession(Success: Boolean);
Var
  secs: Double;
  s: String;
  NextClient: TLSocket;
Begin
  If fProgressVisible Then Begin
    writeln('');
    fProgressVisible := false;
    fProgressLen := 0;
  End;
  secs := (GetTickCount64 - fStatStart) / 1000;
  s := format('%d file(s) sent, %d skipped, %s in %0.1f s', [fStatFiles, fStatSkipped, FormatSize(fStatBytes), secs]);
  If secs > 0 Then s := s + ' (' + FormatSize(round(fStatBytes / secs)) + '/s)';
  If Success Then Begin
    LogShow('Done: ' + s, llInfo);
  End
  Else Begin
    LogShow('Aborted: ' + s, llWarning);
    SetExitStatus(ecError);
  End;
  If Assigned(fFileSendInfo.AktualFile) Then fFileSendInfo.AktualFile.Free;
  fFileSendInfo.AktualFile := Nil;
  fClient := Nil;
  inc(fSessionCount);
  If (MaxSessions <> 0) And (fSessionCount >= MaxSessions) Then Begin
    fRunning := false;
    exit;
  End;
  // Weiter mit dem nächsten npoll
  fState := psWaitForConnection;
  fHandleWaitForConnectionCounter := 0;
  fWaitStart := GetTickCount64;
  If MaxSessions = 0 Then Begin
    LogShow(format('%d npoll(s) served, waiting for the next one, press ESC to exit.', [fSessionCount]), llInfo);
  End
  Else Begin
    LogShow(format('%d of %d npoll(s) served, waiting for the next one...', [fSessionCount, MaxSessions]), llInfo);
  End;
  If fPending.Count > 0 Then Begin
    NextClient := TLSocket(fPending[0]);
    fPending.Delete(0);
    StartSession(NextClient);
  End;
End;

Procedure TNPush.OnTCPAcceptEvent(aSocket: TLSocket);
Begin
  Log('Got tcp connection from : ' + aSocket.PeerAddress, llTrace);
  If fState = psWaitForConnection Then Begin
    StartSession(aSocket);
  End
  Else Begin
    // Wir bedienen gerade ein anderes npoll, dieses kommt danach dran
    Log('Busy, queue : ' + aSocket.PeerAddress, llInfo);
    fPending.Add(aSocket);
  End;
End;

Procedure TNPush.NextFile;
Var
  cnt, cnt2, i: integer;
  md5: TMD5Digest;
  i64: int64;
Begin
  If fFileSendInfo.FileSendState = fssReadyForNextFile Then Begin // Nur, wenn die Aktuelle Datei abgeschlossen ist gehts mit der nächsten weiter
    LogShow(fDestFileList[0], llInfo); // Dem User Anzeigen welche Datei als nächstes versendet werden soll
    If assigned(fClient) Then Begin
      If Assigned(fFileSendInfo.AktualFile) Then fFileSendInfo.AktualFile.Free;
      fFileSendInfo.AktualFile := Nil;
      If CheckMD5 Then Begin
        log('Create MD5 from : ' + fSourceFilelist[0], llTrace);
        md5 := MD5File(fSourceFilelist[0], BufferSize);
        log('MD5 = ' + MDPrint(md5), llTrace);
      End
      Else Begin
        FillChar(md5, sizeof(md5), 0);
      End;
      fFileSendInfo.AktualFile := TFileStream.Create(UTF8ToSys(fSourceFilelist[0]), fmOpenRead);
      fFileSendInfo.Position := 0;
      cnt := 1 + 16 + 8 + 4;
      fFileSendInfo.FileSize := fFileSendInfo.AktualFile.Size;
      setlength(fFileSendInfo.HeaderBytes, 29 + length(fDestFileList[0]));
      If CheckMD5 Then Begin
        If AppendData Then Begin
          fFileSendInfo.HeaderBytes[0] := 9; // 27 ist das Beenden Signal -- Übertragen mit MD5 Check, mit Vortsetzen der evtl schon existierenden Datei
        End
        Else Begin
          fFileSendInfo.HeaderBytes[0] := 1; // 27 ist das Beenden Signal -- Übertragen mit MD5 Check
        End;
      End
      Else Begin
        If AppendData Then Begin
          fFileSendInfo.HeaderBytes[0] := 10; // 27 ist das Beenden Signal -- Übertragen ohne MD5 Check, mit Vortsetzen der evtl schon existierenden Datei
        End
        Else Begin
          fFileSendInfo.HeaderBytes[0] := 2; // 27 ist das Beenden Signal -- Übertragen ohne MD5 Check
        End;
      End;
      For i := 0 To 15 Do Begin // 1 .. 15
        fFileSendInfo.HeaderBytes[1 + i] := md5[i];
      End;
      i64 := fFileSendInfo.FileSize;
      For i := 0 To 7 Do Begin // 16 ..
        fFileSendInfo.HeaderBytes[24 - i] := i64 And $FF;
        i64 := i64 Shr 8;
      End;
      cnt2 := length(fDestFileList[0]); // Anzahl der Zeichen für den Dateinamen übertragen
      fFileSendInfo.HeaderBytes[25] := (cnt2 Shr 24) And $FF;
      fFileSendInfo.HeaderBytes[26] := (cnt2 Shr 16) And $FF;
      fFileSendInfo.HeaderBytes[27] := (cnt2 Shr 8) And $FF;
      fFileSendInfo.HeaderBytes[28] := (cnt2 Shr 0) And $FF;
      cnt := cnt + cnt2;
      For i := 1 To cnt2 Do Begin
        fFileSendInfo.HeaderBytes[28 + i] := ord(fDestFileList[0][i]);
      End;
      // Generieren der Anfrage ob die Nächste Datei gesendet werden soll.
      cnt2 := fClient.Send(fFileSendInfo.HeaderBytes[0], cnt);
      If cnt2 = cnt Then Begin
        // Wir konnten alle Daten versenden
        setlength(fFileSendInfo.HeaderBytes, 0);
        fFileSendInfo.FileSendState := fssWaitForCRCResponse;
        fSourceFilelist.Delete(0);
        fDestFileList.Delete(0);
      End
      Else Begin
        fFileSendInfo.HeaderBytePointer := cnt2;
        fFileSendInfo.FileSendState := fssWaitForHeaderTransfer;
        OnTCPCanSendEvent(fClient);
      End;
    End
    Else Begin
      log('No client to sent data to found.', llCritical);
      EndSession(false);
    End;
  End;
End;

Procedure TNPush.OnTCPReceiveEvent(aSocket: TLSocket);
Var
  Buffer: Array[0..BufferSize - 1] Of byte;
  i, Cnt: integer;
  i64: int64;
  SomethingWasRead: Boolean;
Begin
  If aSocket <> fClient Then exit; // Wartende npoll's senden nichts, bevor sie dran sind
  Repeat
    SomethingWasRead := false;
    Case fState Of
      psTransferFiles: Begin
          Case fFileSendInfo.FileSendState Of
            fssWaitForCRCResponse: Begin
                cnt := aSocket.Get(buffer, 1);
                If cnt > 0 Then SomethingWasRead := true;
                If cnt <> 1 Then Begin
                  // Noch keine Antwort da, der nächste OnReceive liefert sie
                  exit;
                End;
                Case buffer[0] Of
                  8: Begin
                      // Die Position kommt danach, evtl. aufgeteilt auf mehrere Pakete
                      fFileSendInfo.ResumeBytesPointer := 0;
                      fFileSendInfo.FileSendState := fssWaitForResumeOffset;
                    End;
                  ord('N'): Begin
                      inc(fStatSkipped);
                      fFileSendInfo.FileSendState := fssReadyForNextFile;
                    End;
                  ord('Y'): Begin
                      // Die Dateiübertragung kann Beginnen
                      FileStarted;
                      OnTCPCanSendEvent(aSocket);
                    End;
                  ord('A'): Begin // Npoll hat ein Problem Abbruch
                      LogShow('npoll aborted the transfer.', llWarning);
                      EndSession(false);
                      exit;
                    End;
                End;
              End;
            fssWaitForResumeOffset: Begin
                cnt := aSocket.Get(buffer, 8 - fFileSendInfo.ResumeBytesPointer);
                If cnt > 0 Then SomethingWasRead := true;
                For i := 0 To cnt - 1 Do Begin
                  fFileSendInfo.ResumeBytes[fFileSendInfo.ResumeBytesPointer + i] := buffer[i];
                End;
                fFileSendInfo.ResumeBytesPointer := fFileSendInfo.ResumeBytesPointer + cnt;
                If fFileSendInfo.ResumeBytesPointer = 8 Then Begin
                  i64 := 0;
                  For i := 0 To 7 Do Begin
                    i64 := i64 Shl 8;
                    i64 := i64 Or fFileSendInfo.ResumeBytes[i];
                  End;
                  fFileSendInfo.Position := i64;
                  // Die Dateiübertragung setzt fort
                  If i64 > 0 Then Log('Resume at : ' + FormatSize(i64), llInfo);
                  FileStarted;
                  OnTCPCanSendEvent(aSocket);
                End;
              End;
          End;
        End;
      psPing: Begin
          cnt := aSocket.Get(buffer, length(Buffer));
          If cnt > 0 Then SomethingWasRead := true;
          writeln('Got ping from : ' + aSocket.PeerAddress);
          fRunning := false;
        End;
      psChat: Begin
          Repeat
            cnt := aSocket.Get(buffer, length(Buffer));
            If cnt > 0 Then SomethingWasRead := true;
            For i := 0 To cnt - 1 Do Begin
              If Buffer[i] = 13 Then Begin
                writeln('');
              End
              Else Begin
                If buffer[i] = 27 Then Begin
                  fRunning := False;
                End
                Else Begin
                  write(chr(buffer[i]));
                End;
              End;
            End;
          Until cnt = 0;
        End;
    End;
  Until Not SomethingWasRead;
End;

Procedure TNPush.OnUDPDisconnectEvent(aSocket: TLSocket);
Begin
  Log('UDP disconnect', llTrace);
End;

Procedure TNPush.OnTCPDisconnectEvent(aSocket: TLSocket);
Begin
  Log('TCP disconnect', llTrace);
  fPending.Remove(aSocket);
  If (aSocket = fClient) And assigned(fClient) Then Begin
    If fState = psTransferFiles Then Begin
      LogShow('Connection to npoll lost.', llWarning);
      EndSession(false);
    End
    Else Begin
      fClient := Nil;
      fRunning := false;
    End;
  End;
End;

Procedure TNPush.OnTCPCanSendEvent(aSocket: TLSocket);
Var
  cnt: int64;
  Buffer: Array[0..BufferSize - 1] Of byte;
Begin
  //  log('OnTCPCanSendEvent', llTrace); -- Sonst sind zu viele Logs drin
  If aSocket <> fClient Then exit; // Nur an das npoll senden, das gerade bedient wird
  If fFileSendInfo.FileSendState = fssFileTransfering Then Begin
    Repeat
      cnt := min(BufferSize, fFileSendInfo.FileSize - fFileSendInfo.Position);
      fFileSendInfo.AktualFile.Position := fFileSendInfo.Position;
      fFileSendInfo.AktualFile.Read(Buffer, cnt);
      cnt := aSocket.Send(buffer, cnt);
      fFileSendInfo.Position := fFileSendInfo.Position + cnt;
      fStatBytes := fStatBytes + cnt;
      If fFileSendInfo.Position >= fFileSendInfo.FileSize Then Begin
        cnt := 0;
        inc(fStatFiles);
        If fProgressVisible Then ShowProgress(true);
        fFileSendInfo.FileSendState := fssReadyForNextFile;
      End;
    Until cnt = 0;
  End;
  If fFileSendInfo.FileSendState = fssWaitForHeaderTransfer Then Begin
    cnt := aSocket.Send(fFileSendInfo.HeaderBytes[fFileSendInfo.HeaderBytePointer], length(fFileSendInfo.HeaderBytes) - fFileSendInfo.HeaderBytePointer);
    fFileSendInfo.HeaderBytePointer := fFileSendInfo.HeaderBytePointer + cnt;
    If fFileSendInfo.HeaderBytePointer = length(fFileSendInfo.HeaderBytes) Then Begin
      setlength(fFileSendInfo.HeaderBytes, 0);
      fFileSendInfo.FileSendState := fssWaitForCRCResponse;
      fSourceFilelist.Delete(0);
      fDestFileList.Delete(0);
    End;
  End;
End;

Procedure TNPush.OnUDPReceiveEvent(aSocket: TLSocket);
Begin
  // Nichts nur ein Dummy, sonst funktioniert Lnet nicht Richtig
End;

Procedure TNPush.OnUDPErrorEvent(Const msg: String; aSocket: TLSocket);
Begin
  If assigned(aSocket) Then Begin
    logshow('UDP: ' + aSocket.PeerAddress + ': ' + msg, llWarning);
  End
  Else Begin
    logshow('UDP: ' + msg, llWarning);
  End;
  logshow('UDP Error, you have to start npoll first.', llFatal);
  SetExitStatus(ecError);
  fRunning := false;
End;

Procedure TNPush.OnTCPErrorEvent(Const msg: String; aSocket: TLSocket);
Begin
  If assigned(aSocket) Then Begin
    logshow('TCP: ' + aSocket.PeerAddress + ': ' + msg, llWarning);
  End
  Else Begin
    logshow('TCP: ' + msg, llWarning);
  End;
  If assigned(aSocket) And (fPending.IndexOf(aSocket) <> -1) Then Begin
    // Ein wartendes npoll ist weg, das stört die anderen nicht
    fPending.Remove(aSocket);
    exit;
  End;
  If assigned(aSocket) And (aSocket = fClient) And (fState = psTransferFiles) Then Begin
    // Nur diese Sitzung ist kaputt, bei -m geht es mit dem nächsten npoll weiter
    EndSession(false);
    exit;
  End;
  SetExitStatus(ecError);
  fRunning := false;
End;

End.
