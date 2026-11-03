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
Program npoll;

{$MODE objfpc}{$H+}

Uses
{$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
{$ENDIF}{$ENDIF}
  Classes, sysutils, math, ulogger, unpoll;

{$I ../ntools.inc}

Var
  i: Integer;
  np: TNPoll;
  ForceIP: String;
  stayOpen, Quiet, NoOverwrite: Boolean;
  Port, Timeout, rc: Integer;

Begin
  writeln('npoll ver. ' + Version + ' by Corpsman, www.Corpsman.de');
  logger.LogToConsole := true;
  logger.LogToFile := false;
  logger.SetLogLevel(4);
  // logger.SetLogLevel(0);
  ForceIP := '';
  stayOpen := false;
  Quiet := false;
  NoOverwrite := false;
  Timeout := 0;
  Port := DefaultPort;
  For i := 1 To Paramcount Do Begin
    If (lowercase(ParamStr(i)) = '-h') Or
      (lowercase(ParamStr(i)) = '-help') Or
      (lowercase(ParamStr(i)) = '-?') Then Begin
      writeln('Online help');
      writeln('Usage "npoll [Option]');
      writeln('Options :');
      writeln('-l <value> : Set Loglevel to value (valid 0..6) default = 4');
      writeln('-i <IP>    : do not use the udp connection service, connect to ip');
      writeln('-s         : do not close after successfully received files.');
      writeln('-p <value> : Use port value instead of port ' + inttostr(Port));
      writeln('-q         : Do not show the progress automatically');
      writeln('-n         : Do not overwrite existing files, skip them');
      writeln('-t <sec>   : Give up if no npush is found within <sec> seconds');
      writeln('');
      writeln('Info while file transfer:');
      writeln(' i         : show progress (also with -q)');
      writeln('');
      writeln('Exit codes:');
      writeln(' 0 = ok, 1 = aborted by user, 2 = error, 3 = no npush found (-t)');
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
    If lowercase(paramstr(i)) = '-q' Then Begin // Keine automatische Fortschrittsanzeige
      Quiet := true;
    End;
    If lowercase(paramstr(i)) = '-n' Then Begin // Vorhandene Dateien nicht überschreiben
      NoOverwrite := true;
    End;
    If lowercase(paramstr(i)) = '-t' Then Begin // Timeout für das Warten auf npush
      Timeout := max(0, strtointdef(paramstr(i + 1), 0));
    End;
  End;
  np := TNPoll.create(Port);
  np.forceIP := ForceIP;
  np.StayOpen := stayOpen;
  np.Quiet := Quiet;
  np.NoOverwrite := NoOverwrite;
  np.Timeout := Timeout;
  np.execute;
  rc := np.ExitStatus;
  np.free;
  halt(rc);
  //  writeln('Finish'); // Debug to be removed
  //  readln(); // Debug to be removed
End.

