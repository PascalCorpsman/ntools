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
Program npush;

{$MODE objfpc}{$H+}

Uses
{$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  cmem,
{$ENDIF}{$ENDIF}
  Classes, sysutils, math, unpush, ulogger, lNet
  ;

{$I ../ntools.inc}

Var
  Port, i: integer;
  np: TNPush;
  CheckMD5, AppendData, Quiet: Boolean;
  MaxSessions, Timeout, rc: integer;
  BIP: String;

Begin
  writeln('npush ver. ' + Version + ' by Corpsman, www.Corpsman.de');
  logger.LogToConsole := true;
  logger.LogToFile := false;
  logger.SetLogLevel(4);
  // logger.SetLogLevel(0); // Debug to be removed
  CheckMD5 := false;
  AppendData := false;
  Quiet := false;
  MaxSessions := 1;
  Timeout := 0;
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
      writeln(' -q         : Do not show the progress automatically');
      writeln(' -t <sec>   : Give up if no npoll is found within <sec> seconds');
      writeln(' -m <n>     : Send to <n> npoll''s one after another, 0 = until ESC');
      writeln('              (every connection counts, also a second one of the same npoll)');
      writeln('');
      writeln('Info while file transfer:');
      writeln(' i          : show progress (also with -q)');
      writeln('');
      writeln('Exit codes:');
      writeln(' 0 = ok, 1 = aborted by user, 2 = error, 3 = no npoll found (-t)');
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
    If lowercase(ParamStr(i)) = '-q' Then Begin // Keine automatische Fortschrittsanzeige
      Quiet := true;
    End;
    If lowercase(ParamStr(i)) = '-t' Then Begin // Timeout für die Suche nach npoll
      Timeout := max(0, strtointdef(ParamStr(i + 1), 0));
    End;
    If lowercase(ParamStr(i)) = '-m' Then Begin // Mehrere npoll's nacheinander bedienen
      MaxSessions := max(0, strtointdef(ParamStr(i + 1), 1));
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
  np.Quiet := Quiet;
  np.MaxSessions := MaxSessions;
  np.Timeout := Timeout;
  np.Execute;
  rc := np.ExitStatus;
  np.free;
  halt(rc);
  //  writeln('Finish..'); // Debug to be removed
  //  readln(); // Debug to be removed
End.

