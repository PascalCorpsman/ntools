Program npush;

{$MODE objfpc}{$H+}

Uses
{$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  cmem,
{$ENDIF}{$ENDIF}
  Classes, sysutils, unpush, ulogger, lNet
  ;

{$I ../ntools.inc}

Var
  Port, i: integer;
  np: TNPush;
  CheckMD5, AppendData: Boolean;
  BIP: String;

Begin
  writeln('npush ver. ' + Version + ' by Corpsman, www.Corpsman.de');
  logger.LogToConsole := true;
  logger.LogToFile := false;
  logger.SetLogLevel(4);
  // logger.SetLogLevel(0); // Debug to be removed
  CheckMD5 := false;
  AppendData := false;
  Port := DefaultPort;
  bip := LADDR_BR;
  For i := 1 To Paramcount Do Begin
    If (lowercase(ParamStr(i)) = '-h') Or
      (lowercase(ParamStr(i)) = '-help') Or
      (lowercase(ParamStr(i)) = '-?') Then Begin // Print Help
      writeln('Online help');
      writeln('');
      writeln('Always start npoll first');
      writeln('');
      writeln('Examples to call npush');
      writeln(' Test connection                   : npush');
      writeln(' Open chat                         : npush -c');
      writeln(' Transfer file[s]                  : npush <Filename> [ <Filename>]');
      writeln(' Transfer all local files          : npush *.*');
      writeln(' Transfer all local files of type  : npush *.<type>');
      writeln(' Transfer all local files of type  : npush "*.<type> [;*.<type>]"');
      writeln(' Transfer all files and subfolders : npush *');
      writeln('');
      writeln('Additional options:');
      writeln(' -p <value> : Use port value instead of port ' + inttostr(Port));
      writeln(' -md5       : Use MD5 Checksum to proove if transfer is needed');
      writeln(' -a         : Append data to files, that are not transfered complete');
      writeln(' -i         : Overwrite broadcast ip for udp connection');
      writeln('');
      writeln('Info while file transfer:');
      writeln(' i          : show progress');
      halt;
    End;
    If lowercase(ParamStr(i)) = '-l' Then Begin // Überschreiben Loglevel
      logger.SetLogLevel(strtointdef(ParamStr(i + 1), 0));
    End;
    If lowercase(ParamStr(i)) = '-md5' Then Begin // Einschalten MD5 Checksummen Modus
      CheckMD5 := true;
    End;
    If lowercase(ParamStr(i)) = '-a' Then Begin // Aktivieren Append Modus
      AppendData := true;
    End;
    If lowercase(paramstr(i)) = '-p' Then Begin // Force IP Modus Aktivieren
      Port := strtointdef(paramstr(i + 1), DefaultPort);
      LogShow('Use port : ' + inttostr(port), llInfo);
    End;
    If lowercase(paramstr(i)) = '-i' Then Begin // Force IP Modus Aktivieren
      bip := paramstr(i + 1);
      LogShow('Use broadcast ip : ' + bip, llInfo);
    End;
  End;
  np := TNPush.create(port);
  np.CheckMD5 := CheckMD5;
  np.AppendData := AppendData;
  np.UDPBroadCastIP := bip;
  np.Execute;
  np.free;
  //  writeln('Finish..'); // Debug to be removed
  //  readln(); // Debug to be removed
End.

