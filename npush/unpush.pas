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

  TFileSendState = (
    fssReadyForNextFile, // Alles Aktuelle ist Abgearbeitet, Starten mit der Nächste zu übertragenden Datei
    fssWaitForCRCResponse, // Anfrage bei Npoll ob die Datei gesendert werden soll
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
  End;

  { TNPush }

  TNPush = Class
  private
    fudp: TLUdp;
    ftcp: TLTcp;
    fPort: Word;
    fState: TPushState;
    fRunning: Boolean;
    fHandleWaitForConnectionCounter: integer;
    fSourceFilelist: TSTringlist;
    fDestFileList: TSTringlist;
    fFileSendInfo: TFileSendInfo;
    Procedure OnUDPErrorEvent(Const msg: String; aSocket: TLSocket);
    Procedure OnUDPDisconnectEvent(aSocket: TLSocket);
    Procedure OnUDPReceiveEvent(aSocket: TLSocket);

    Procedure OnTCPErrorEvent(Const msg: String; aSocket: TLSocket);
    Procedure OnTCPReceiveEvent(aSocket: TLSocket);
    Procedure OnTCPDisconnectEvent(aSocket: TLSocket);
    Procedure OnTCPCanSendEvent(aSocket: TLSocket);
    Procedure OnTCPAcceptEvent(aSocket: TLSocket);

    Procedure NextFile;

    Procedure HandleWaitForConnection;
    Procedure HandleChat;
    Procedure HandlePing;
    Procedure HandleTransferFiles;
  public
    AppendData: Boolean;
    CheckMD5: Boolean;
    UDPBroadCastIP: String;
    Constructor create(Port: integer);
    Destructor destroy; override;
    Procedure Execute;
  End;

Implementation

Uses ulogger, crt, FileUtil, LazUTF8, LazFileUtils, math, md5, uip;

Const
  Welcome_Message = 'Hello';

  { TNPush }

Constructor TNPush.create(Port: integer);
Begin
  Inherited create;
  Log('npush ver. 0.01', llTrace);
  Log('npush ver. 0.01', llInfo);
  UDPBroadCastIP := LADDR_BR;
  fPort := Port;
  CheckMD5 := false;
  AppendData := false;
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
  fHandleWaitForConnectionCounter := 0;
  fSourceFilelist := Nil;
  fDestFileList := Nil;
End;

Destructor TNPush.destroy;
Begin
  Log('destroy', llTrace);
  If assigned(fSourceFilelist) Then fSourceFilelist.free;
  fSourceFilelist := Nil;
  If assigned(fDestFileList) Then fDestFileList.free;
  fDestFileList := Nil;
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
End;

Procedure TNPush.Execute;
Begin
  // 1.1 Alle Server Starten
  logger.Log('Creating Connections.', llTrace);
  frunning := true;
  If Not fudp.Connect(''{localhost}, fPort) Then Begin // Die Windows Version funktioniert so am besten ...
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
  End;
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
        bip := CalculateBroadCastAddressFromAddress(n[i].IpAddress, n[i].SubnetMask);
        logger.Log('Ping to : ' + bip, llTrace);
        fudp.SendMessage(Welcome_Message, bip);
      End;
    End;
  End;
  If KeyPressed Then Begin // Abbruch durch Benutzer
    If ReadKey = #27 Then Begin
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
    ftcp.SendMessage(k);
  End;
End;

Procedure TNPush.HandlePing;
Begin
  If KeyPressed Then Begin // Abbruch durch Benutzer
    If ReadKey = #27 Then Begin
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
      fRunning := false;
    End;
    If c = 'i' Then Begin
      If fFileSendInfo.FileSendState = fssFileTransfering Then Begin
        writeln(format('%d kB from %d kB = %0.1f%%', [round(fFileSendInfo.Position / 1024), round(fFileSendInfo.FileSize / 1024), (fFileSendInfo.Position * 100) / fFileSendInfo.FileSize]));
      End;
    End;
  End;
  If fRunning Then Begin
    Case fFileSendInfo.FileSendState Of
      fssReadyForNextFile: Begin
          If fSourceFilelist.Count = 0 Then Begin
            //Fertig, kontrolliert runter fahren
            ftcp.SendMessage(#27);
            fRunning := false;
          End
          Else Begin
            NextFile;
          End;
        End;
    End;
  End;
End;

Procedure TNPush.OnTCPAcceptEvent(aSocket: TLSocket);
Var
  j, i: Integer;
  sl: Tstringlist;
  tmp, s: String;
Begin
  If fState = psWaitForConnection Then Begin
    Log('Got tcp connection from : ' + aSocket.PeerAddress, llTrace);
    // Auswerten der Übergabeparameter und entscheiden welcher der 3 Usecases wir haben
    i := 0;
    fSourceFilelist := TStringList.Create;
    fDestFileList := TStringList.Create;
    Repeat
      inc(i);
      If lowercase(ParamStrUTF8(i)) = '-l' Then Begin // Überspringen der Set Loglevel Parameter
        inc(i, 2);
      End;
      If lowercase(ParamStrUTF8(i)) = '-c' Then Begin // Öffne den Chat Modus
        fState := psChat;
        Logshow('Open chat mode, press ESC to exit.', llInfo);
        aSocket.SendMessage('1'); // Steuercode 1 => Chat Modus
        exit;
      End;
      tmp := ParamStrUTF8(i); // Debug
      // Versuch ein Verzeichnis zu versenden
      If DirectoryExistsUTF8(trim(ParamStrUTF8(i))) Then Begin
        If (pos(GetCurrentDirUTF8, trim(ParamStrUTF8(i))) = 1) Then Begin
          sl := FindAllFiles(trim(ParamStrUTF8(i)), '', true);
          For j := 0 To sl.Count - 1 Do Begin
            fSourceFilelist.add(sl[j]);
            fDestFileList.Add(copy(sl[j], length(trim(GetCurrentDirUTF8)) + 1, length(sl[j])));
          End;
          sl.free;
        End
        Else Begin
          If DirectoryExistsUTF8(IncludeTrailingPathDelimiter(GetCurrentDirUTF8) + trim(ParamStrUTF8(i))) Then Begin
            sl := FindAllFiles(IncludeTrailingPathDelimiter(GetCurrentDirUTF8) + trim(ParamStrUTF8(i)), '', true);
            For j := 0 To sl.Count - 1 Do Begin
              fSourceFilelist.add(sl[j]);
              fDestFileList.Add(copy(sl[j], length(GetCurrentDirUTF8) + 1, length(sl[j])));
            End;
            sl.free;
          End
          Else Begin
            // Es wurde ein Verzeichnis Übergeben wir schneiden den Namen aus und übergeben alles drunter
            s := ExcludeTrailingPathDelimiter(trim(ParamStrUTF8(i)));
            s := IncludeTrailingPathDelimiter(ExtractFilePath(s));
            sl := FindAllFiles(trim(ParamStrUTF8(i)), '', true);
            For j := 0 To sl.count - 1 Do Begin
              fSourceFilelist.Add(sl[j]);
              fDestFileList.add(copy(sl[j], length(s), length(sl[j])));
            End;
            sl.free;
          End;
        End;
        Continue;
      End;

      If FileExistsUTF8(trim(ParamStrUTF8(i))) Then Begin // Geöffnet im File Transfer modus eine oder mehrere Dateien
        If DirectoryExistsUTF8(trim(ParamStrUTF8(i))) Then Begin // -- TOdo das kann sicherlich gelöscht werden weil wir ja wissen dass es sich um eine Datei und kein Verzeichnis handelt
          If (pos(GetCurrentDirUTF8, trim(ParamStrUTF8(i))) = 1) Then Begin
            sl := FindAllFiles(trim(ParamStrUTF8(i)), '', true);
            For j := 0 To sl.Count - 1 Do Begin
              fSourceFilelist.add(sl[j]);
              fDestFileList.Add(copy(sl[j], length(GetCurrentDirUTF8) + 1, length(sl[j])));
            End;
            sl.free;
          End
          Else Begin
            If DirectoryExistsUTF8(IncludeTrailingPathDelimiter(GetCurrentDirUTF8) + trim(ParamStrUTF8(i))) Then Begin
              sl := FindAllFiles(IncludeTrailingPathDelimiter(GetCurrentDirUTF8) + trim(ParamStrUTF8(i)), '', true);
              For j := 0 To sl.Count - 1 Do Begin
                fSourceFilelist.add(sl[j]);
                fDestFileList.Add(copy(sl[j], length(GetCurrentDirUTF8) + 1, length(sl[j])));
              End;
              sl.free;
            End
            Else Begin
              // Es wurde ein Verzeichnis Übergeben wir schneiden den Namen aus und übergeben alles drunter
              s := ExcludeTrailingPathDelimiter(trim(ParamStrUTF8(i)));
              s := IncludeTrailingPathDelimiter(ExtractFilePath(s));
              sl := FindAllFiles(trim(ParamStrUTF8(i)), '', true);
              For j := 0 To sl.count - 1 Do Begin
                fSourceFilelist.Add(sl[j]);
                fDestFileList.add(copy(sl[j], length(s), length(sl[j])));
              End;
              sl.free;
            End;
          End;
        End
        Else Begin
          If FileExistsUTF8(trim(ParamStrUTF8(i))) Then Begin
            fSourceFilelist.Add(trim(ParamStrUTF8(i)));
            fDestFileList.add(ExtractFileName(trim(ParamStrUTF8(i))));
          End;
        End;
        Continue;
      End;
      If (trim(ParamStrUTF8(i)) = '*.*') Then Begin // Geöffnet im Alle Lokalen Dateien übertragen Modus
        Log('Sent all files', llInfo);
        sl := FindAllFiles(GetCurrentDirUTF8, '', false);
        For j := 0 To sl.Count - 1 Do Begin
          fSourceFilelist.Add(sl[j]);
          fDestFileList.Add(copy(sl[j], length(GetCurrentDirUTF8) + 1, length(sl[j])));
        End;
        sl.free;
        fFileSendInfo.FileSendState := fssReadyForNextFile;
        fState := psTransferFiles;
        aSocket.SendMessage('2'); // Steuercode 2 => Sende eine Beliebige Anzahl an Dateien
        exit;
      End;
      If pos('*.', trim(ParamStrUTF8(i))) = 1 Then Begin // Geöffnet im Übertrage Alle Dateien der Art *.xyz
        Log('Sent all files of type', llInfo);
        sl := FindAllFiles(GetCurrentDirUTF8, trim(ParamStrUTF8(i)), false);
        For j := 0 To sl.Count - 1 Do Begin
          fSourceFilelist.add(sl[j]);
          fDestFileList.Add(copy(sl[j], length(GetCurrentDirUTF8) + 1, length(sl[j])));
        End;
        sl.free;
        fFileSendInfo.FileSendState := fssReadyForNextFile;
        fState := psTransferFiles;
        aSocket.SendMessage('2'); // Steuercode 2 => Sende eine Beliebige Anzahl an Dateien
        exit;
      End;
      If (trim(ParamStrUTF8(i)) = '*') Then Begin // Geöffnet im Übertrage alle Dateien und Unterordner
        Log('Sent all files and subfolders', llInfo);
        sl := FindAllFiles(GetCurrentDirUTF8, '', true);
        For j := 0 To sl.Count - 1 Do Begin
          fSourceFilelist.add(sl[j]);
          fDestFileList.Add(copy(sl[j], length(GetCurrentDirUTF8) + 1, length(sl[j])));
        End;
        sl.free;
        fFileSendInfo.FileSendState := fssReadyForNextFile;
        fState := psTransferFiles;
        aSocket.SendMessage('2'); // Steuercode 2 => Sende eine Beliebige Anzahl an Dateien
        exit;
      End;
    Until i >= Paramcount; // Ende Auslesen der Übergabeparameter
    // Es bleint nur noch senden von Dateien oder Ping
    If fSourceFilelist.Count > 0 Then Begin
      Log('Sent file list', llInfo);
      fFileSendInfo.FileSendState := fssReadyForNextFile;
      fState := psTransferFiles;
      aSocket.SendMessage('2'); // Steuercode 2 => Sende eine Beliebige Anzahl an Dateien
    End
    Else Begin
      //Nur ein "Ping" und gleich wieder zu machen
      Log('Sent a ping', llInfo);
      fstate := psPing;
      aSocket.SendMessage('0'); // Steuercode 0 => Ping, dann Beenden
    End;
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
    ftcp.IterReset;
    ftcp.IterNext; // Skip Root Socket
    If assigned(ftcp.Iterator) Then Begin
      If Assigned(fFileSendInfo.AktualFile) Then fFileSendInfo.AktualFile.Free;
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
      cnt2 := ftcp.Iterator.Send(fFileSendInfo.HeaderBytes[0], cnt);
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
        ftcp.OnCanSend(ftcp.Iterator);
      End;
    End
    Else Begin
      log('No client to sent data to found.', llCritical);
      fRunning := false;
    End;
  End;
End;

Procedure TNPush.OnTCPReceiveEvent(aSocket: TLSocket);
Var
  Buffer: Array[0..BufferSize - 1] Of byte;
  i, Cnt: integer;
  i64: int64;
Begin
  Case fState Of
    psTransferFiles: Begin
        Case fFileSendInfo.FileSendState Of
          fssWaitForCRCResponse: Begin
              cnt := aSocket.Get(buffer, 1);
              If cnt <> 1 Then Begin
                fRunning := false;
                exit;
              End;
              Case buffer[0] Of
                8: Begin
                    cnt := aSocket.Get(buffer, 8);
                    If cnt = 8 Then Begin
                      i64 := 0;
                      For i := 0 To 7 Do Begin
                        i64 := i64 Shl 8;
                        i64 := i64 Or buffer[i];
                      End;
                      fFileSendInfo.Position := i64;
                      // Die Dateiübertragung setzt fort
                      fFileSendInfo.FileSendState := fssFileTransfering;
                      OnTCPCanSendEvent(aSocket);
                    End
                    Else Begin
                      fRunning := false;
                      Raise Exception.Create('Verdammt FileSize nicht Vollständig empfangen.');
                    End;
                  End;
                ord('N'): Begin
                    fFileSendInfo.FileSendState := fssReadyForNextFile;
                  End;
                ord('Y'): Begin
                    // Die Dateiübertragung kann Beginnen
                    fFileSendInfo.FileSendState := fssFileTransfering;
                    OnTCPCanSendEvent(aSocket);
                  End;
                ord('A'): Begin // Npoll hat ein Problem Abbruch
                    fRunning := false;
                  End;
              End;
            End;
        End;
      End;
    psPing: Begin
        cnt := aSocket.Get(buffer, length(Buffer));
        writeln('Got ping from : ' + aSocket.PeerAddress);
        fRunning := false;
      End;
    psChat: Begin
        Repeat
          cnt := aSocket.Get(buffer, length(Buffer));
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
End;

Procedure TNPush.OnUDPDisconnectEvent(aSocket: TLSocket);
Begin
  Log('UDP disconnect', llTrace);
End;

Procedure TNPush.OnTCPDisconnectEvent(aSocket: TLSocket);
Begin
  Log('TCP disconnect', llTrace);
End;

Procedure TNPush.OnTCPCanSendEvent(aSocket: TLSocket);
Var
  cnt: int64;
  Buffer: Array[0..BufferSize - 1] Of byte;
Begin
  //  log('OnTCPCanSendEvent', llTrace); -- Sonst sind zu viele Logs drin
  If fFileSendInfo.FileSendState = fssFileTransfering Then Begin
    Repeat
      cnt := min(BufferSize, fFileSendInfo.FileSize - fFileSendInfo.Position);
      fFileSendInfo.AktualFile.Position := fFileSendInfo.Position;
      fFileSendInfo.AktualFile.Read(Buffer, cnt);
      cnt := aSocket.Send(buffer, cnt);
      fFileSendInfo.Position := fFileSendInfo.Position + cnt;
      If fFileSendInfo.Position >= fFileSendInfo.FileSize Then Begin
        cnt := 0;
        fFileSendInfo.FileSendState := fssReadyForNextFile;
      End;
    Until cnt = 0;
  End;
  If fFileSendInfo.FileSendState = fssWaitForHeaderTransfer Then Begin
    cnt := aSocket.Send(fFileSendInfo.HeaderBytes[fFileSendInfo.HeaderBytePointer], length(fFileSendInfo.HeaderBytes) - fFileSendInfo.HeaderBytePointer);
    If fFileSendInfo.HeaderBytePointer + cnt = length(fFileSendInfo.HeaderBytes) Then Begin
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
  fRunning := false;
End;

End.

