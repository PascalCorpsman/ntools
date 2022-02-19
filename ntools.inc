
Const
  (*
   * Historie : 0.01 = Initialversion
   *            0.02 = freischalten Option -p
   *                   Bugfix Option -i
   *            0.03 = Bugfix NPush beim einlesen von verzeichnissen wurde nur die 1. Datei kopiert (dafür aber so oft wie es Dateien im Verzeichnis gab)
   *                   -i Option für npush
   *            0.04 = Sendennun auch mit "zerlegten" headern
   *            0.05 = npush aktzeptiert nun auch, wenn die Paramstr( * ) mit einem crt terminiert sind
   *            0.06 = die LCL hat sich geändert, daher waren Anpassungen notwendig
   *            0.07 = npush sendet den UDP-Broadcast nun auf allen Adaptern
   *)
  Version = '0.07';
  //  BufferSize = 32768; // ACHTUNG darf auf keinen Fall größer sein wie 65536, oder Kleiner als 128 => 4.800.000
  BufferSize = 16384; // ACHTUNG darf auf keinen Fall größer sein wie 65536, oder Kleiner als 128 => 12.000.000
  //  BufferSize = 8192;  // ACHTUNG darf auf keinen Fall größer sein wie 65536, oder Kleiner als 128 => 4.800.000
  //  BufferSize = 4096;  // ACHTUNG darf auf keinen Fall größer sein wie 65536, oder Kleiner als 128
  DefaultPort = 8002;

