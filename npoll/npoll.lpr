Program npoll;

{$MODE objfpc}{$H+}

Uses
{$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
{$ENDIF}{$ENDIF}
  Classes, sysutils, ulogger, unpoll;

{$I ../ntools.inc}

Var
  i: Integer;
  np: TNPoll;
  ForceIP: String;
  stayOpen: Boolean;
  Port: Integer;

Begin
  writeln('npoll ver. ' + Version + ' by Corpsman, www.Corpsman.de');
  logger.LogToConsole := true;
  logger.LogToFile := false;
  logger.SetLogLevel(4);
  // logger.SetLogLevel(0);
  ForceIP := '';
  stayOpen := false;
  Port := DefaultPort;
  For i := 1 To Paramcount Do Begin
    If (lowercase(ParamStr(i)) = '-h') Or
      (lowercase(ParamStr(i)) = '-help') Or
      (lowercase(ParamStr(i)) = '-?') Then Begin
      writeln('Online help');
      writeln('Usage "npoll [Option]');
      writeln('Options :');
      writeln('-l <value> : Set Loglevel to value (valid 0..6) default = 4');
      writeln('-i <IP>    : du not use the udp connection service connect to ip');
      writeln('-s         : do not close after successfully received files.');
      writeln('-p <value> : Use port value instead of port ' + inttostr(Port)); // Todo : Implementieren
      writeln('');
      writeln('Info while file transfer:');
      writeln(' i         : show progress');
      halt(0);
    End;
    If lowercase(paramstr(i)) = '-l' Then Begin
      logger.SetLogLevel(strtointdef(paramstr(i + 1), 0));
    End;
    If lowercase(paramstr(i)) = '-p' Then Begin // Force IP Modus Aktivieren
      Port := strtointdef(paramstr(i + 1), DefaultPort);
      LogShow('Use port : ' + inttostr(Port), llInfo);
    End;
    If lowercase(paramstr(i)) = '-i' Then Begin // Force IP Modus Aktivieren
      ForceIP := paramstr(i + 1);
      LogShow('Use ip : ' + ForceIP, llInfo);
    End;
    If lowercase(paramstr(i)) = '-s' Then Begin // Stay Open Modus Aktivieren
      stayOpen := true;
    End;
  End;
  np := TNPoll.create(Port);
  np.forceIP := ForceIP;
  np.StayOpen := stayOpen;
  np.execute;
  np.free;
  //  writeln('Finish'); // Debug to be removed
  //  readln(); // Debug to be removed
End.

