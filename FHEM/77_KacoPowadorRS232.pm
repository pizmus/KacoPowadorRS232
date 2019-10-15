################################################################################
#
#    77_KacoPowadorRS232.pm
#
#    Copyright (C) 2019  pizmus
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################

package main;
use strict;
use warnings;

sub
KacoPowadorRS232_Initialize($)
{
  my ($hash) = @_;
  $hash->{DefFn}         = "KacoPowadorRS232_Define";
  $hash->{UndefFn}       = "KacoPowadorRS232_Undef";
  $hash->{SetFn}         = "KacoPowadorRS232_Set";
  $hash->{ReadFn}        = "KacoPowadorRS232_Read";
  $hash->{DeleteFn}      = "KacoPowadorRS232_Delete";
  $hash->{ReadyFn}       = "KacoPowadorRS232_Ready";
  $hash->{AttrList}      = $readingFnAttributes;
}

sub
KacoPowadorRS232_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t]+", $def);

  my $name = $a[0];

  # $a[1] always equals the module name

  # first argument is the serial port (e.g. /dev/ttyUSB0)
  my $dev = $a[2]."\@9600,8,N,1";

  return "no device given" unless($dev);

  Log3 $name, 3, "KacoPowadorRS232 ($name) - define: $dev";

  $hash->{DeviceName} = $dev;

  # close connection if maybe open (on definition modify)
  DevIo_CloseDev($hash) if(DevIo_IsOpen($hash));

  # open connection with custom init and error callback function (non-blocking connection establishment)
  DevIo_OpenDev($hash, 0, "KacoPowadorRS232_Init", "KacoPowadorRS232_Callback");

  KacoPowadorRS232_SetStatus($hash, "defined");

  KacoPowadorRS232_InternalReset($hash);

  return undef;
}

sub
KacoPowadorRS232_Init($)
{
  my ($hash) = @_;
  KacoPowadorRS232_SetStatus($hash, "connected");
  return undef;
}

sub
KacoPowadorRS232_Callback($$)
{
  my ($hash, $error) = @_;
  my $name = $hash->{NAME};

  if ($error)
  {
    KacoPowadorRS232_SetStatus($hash, "disconnected");
    Log3 $name, 1, "KacoPowadorRS232 ($name) - error while connecting: >>".$error."<<";
  }

  return undef;
}

sub
KacoPowadorRS232_Undef($$)
{
  my ($hash, $arg) = @_;

  # close the connection
  DevIo_CloseDev($hash);

  RemoveInternalTimer($hash);
  delete( $modules{KacoPowadorRS232}{defptr} );

  return undef;
}

sub
KacoPowadorRS232_Delete($$)
{
  my ($hash, $name) = @_;
  #delete all dev-spec temp-files
  unlink($attr{global}{modpath}. "/FHEM/FhemUtils/$name.tmp");
  return undef;
}

sub
KacoPowadorRS232_InternalReset($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  
  RemoveInternalTimer($hash);
  
  $hash->{SECONDS_TODAY} = 0;
  $hash->{ENERGY_TODAY} = 0;
  
  my $readingTimestamp = ReadingsTimestamp($name, "energyToday", undef);
  my $readingDateString = undef;
  if (defined $readingTimestamp) 
  {
    if ($readingTimestamp =~ m/^([0-9\-]+)\s/)
    {
      $readingDateString = $1;
    }   
  }
  
  my $currentTime = FmtDateTime(gettimeofday());
  # example: 2016-02-16 19:34:24
  my $currentDateString;
  if (defined $currentTime)    
  {
    if ($currentTime =~ m/^([0-9\-]+)\s/)
    {
      $currentDateString = $1;
    }    
  }

  # If the last sample of energyToday was from earlier today:
  # Restore hash entry ENGERGY_TODAY from the reading, so that 
  # accumulation can continue at the best possible point, e.g.
  # after a restart.
  if ((defined $currentDateString) && (defined $readingDateString))      
  {
    if ($currentDateString eq $readingDateString)
    {
      $hash->{ENERGY_TODAY} = ReadingsNum($name, "energyToday", 0);
    }
  }
}

sub
KacoPowadorRS232_Reset($)
{
  my ($hash) = @_;
  
  DevIo_CloseDev($hash) if(DevIo_IsOpen($hash));
  KacoPowadorRS232_SetStatus($hash, "disconnected");
  DevIo_OpenDev($hash, 0, "KacoPowadorRS232_Init", "KacoPowadorRS232_Callback");

  return KacoPowadorRS232_InternalReset($hash);
}

sub
KacoPowadorRS232_IsNewDay($)
{
  my ($hash) = @_;  
  
  my $timestamp = FmtDateTime(gettimeofday());
  # example: 2016-02-16 19:34:24
  
  if ($timestamp =~ m/^([0-9\-]+)\s/)
  {
    my $dateString = $1;
    
    if (defined $hash->{DATE_OF_LAST_SAMPLE})
    {
      if (!($hash->{DATE_OF_LAST_SAMPLE} eq $dateString))
      {
        $hash->{DATE_OF_LAST_SAMPLE} = $dateString;
        return 1;
      }
    }
    else
    {
      $hash->{DATE_OF_LAST_SAMPLE} = $dateString;
    }
  }
  
  return undef;
}

sub
KacoPowadorRS232_Read($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $data = DevIo_SimpleRead($hash);
  return if (!defined($data)); # connection lost

  my $buffer = $hash->{PARTIAL};

  $data =~ s/\r//g;

  # concat received data to $buffer
  $buffer .= $data;

  while ($buffer =~ m/\n/)
  {
    my $msg;

    # extract the complete message ($msg), everything else is assigned to $buffer
    ($msg, $buffer) = split("\n", $buffer, 2);

    # remove trailing whitespaces
    chomp $msg;

    Log3 $name, 4, "KacoPowadorRS232 ($name) - COMM Read: $msg";

    my $ascii = $msg;

    if ((length $ascii) == 0)
    {
      Log3 $name, 4, "KacoPowadorRS232 ($name) - COMM - error: empty response detected";
      next;
    }

    # sample message:
    # 00.00.0000 14:54:50 4 354.9 0.38 134 235.7 0.41 97 34

    my @fields = split(' ', $ascii);
    
    if ((scalar @fields) != 10)
    {
      Log3 $name, 4, "KacoPowadorRS232 ($name) - COMM - error: unexpected number of fields in message: ".$ascii;
      next;
    }

    # examine the time field
    my @t = split(/:/, $fields[1]);
    if ((scalar @t) != 3)
    {
      Log3 $name, 4, "KacoPowadorRS232 ($name) - COMM - error: unexpected number of fields in timstamp: ".$fields[1];
      next;
    }
    my $secondsToday = (60 * 60 * $t[0]) + (60 * $t[1]) + $t[2];
    
    # reset daily energy when a new day starts
    if (KacoPowadorRS232_IsNewDay($hash))
    {
      $hash->{ENERGY_TODAY} = 0;
    }
    $hash->{SECONDS_TODAY} = $secondsToday;
    
    my $mode = $fields[2];
    readingsSingleUpdate($hash, "mode", KacoPowadorRS232_convertMode($hash, $mode), 1);
    
    my $power = $fields[8];
    readingsSingleUpdate($hash, "power", $power, 1);
    
    my $temperature = $fields[9];
    readingsSingleUpdate($hash, "temperature", $temperature, 1);
    
    $hash->{ENERGY_TODAY} += $power * 10.0 / 3600.0;
    readingsSingleUpdate($hash, "energyToday", $hash->{ENERGY_TODAY}, 1);    
  }

  $hash->{PARTIAL} = $buffer;
}

sub
KacoPowadorRS232_convertMode($$)
{
  my ($hash, $mode) = @_;
  my $name = $hash->{NAME};
  
  my $modeString = $mode."_";
  
  if ($mode==0) { $modeString .= "gerade_eingeschaltet"; }
  elsif ($mode==1) { $modeString .= "Warten_auf_Start"; }
  elsif ($mode==2) { $modeString .= "Warten_auf_Ausschalten"; }
  elsif ($mode==3) { $modeString .= "Konstantspannungsregler"; }
  elsif ($mode==4) { $modeString .= "MPP-Regler,staendige Suchbewegung"; }
  elsif ($mode==5) { $modeString .= "MPP-Regler,ohne Suchbewegung"; }
  elsif ($mode==6) { $modeString .= "Wartemodus_vor_Einspeisung"; }
  elsif ($mode==7) { $modeString .= "Wartemodus_vor_Selbsttest"; }
  elsif ($mode==8) { $modeString .= "Selbsttest_der_Relais"; }
  elsif ($mode==10) { $modeString .= "Uebertemperaturabschaltung"; }
  elsif ($mode==11) { $modeString .= "Leistungsbegrenzung"; }
  elsif ($mode==12) { $modeString .= "Ueberlastabschaltung"; }
  elsif ($mode==13) { $modeString .= "Ueberspannungsabschaltung"; }
  elsif ($mode==14) { $modeString .= "Netzstoerung"; }
  elsif ($mode==18) { $modeString .= "Fehlerstrom_zu_hoch"; }
  elsif ($mode==19) { $modeString .= "Isolationswert_zu_gering"; }
  elsif ($mode==30) { $modeString .= "Stoerung_Messwandler"; }
  elsif ($mode==31) { $modeString .= "Fehler_Fehlerstromschutzschalter"; }
  elsif ($mode==32) { $modeString .= "Fehler_Selbsttest"; }
  elsif ($mode==33) { $modeString .= "Fehler_DC-Einspeisung"; }
  elsif ($mode==34) { $modeString .= "Fehler_Kommunikation"; }
  else { $modeString .= "unbekannter_Status"; }

  return $modeString;
}

sub
KacoPowadorRS232_Set($$)
{
  my ($hash, @parameters) = @_;
  my $name = $parameters[0];
  my $what = lc($parameters[1]);

  my $commands = ("reset:noArg");

  if ($what eq "reset")
  {
    KacoPowadorRS232_Reset($hash);
  }
  elsif ($what eq "?")
  {
    my $message = "unknown argument $what, choose one of $commands";
    return $message;
  }
  else
  {
    my $message = "unknown argument $what, choose one of $commands";
    Log3 $name, 1, "KacoPowadorRS232 ($name) - ".$message;
    return $message;
  }

  return undef;
}

sub
KacoPowadorRS232_Ready($)
{
  my ($hash) = @_;

  # try to reopen the connection in case the connection is lost
  return DevIo_OpenDev($hash, 1, "KacoPowadorRS232_Init", "KacoPowadorRS232_Callback");
}

sub
KacoPowadorRS232_SetStatus($$)
{
  my ($hash, $status) = @_;
  my $name = $hash->{NAME};

  # check whether given status is an expected value
  if (!(($status eq "defined") ||
        ($status eq "connected") ||
        ($status eq "disconnected") ||
        ($status eq "initializing") ||
        ($status eq "initialized") ||
        ($status eq "ready")))
  {
    Log3 $name, 1, "KacoPowadorRS232 ($name) - Error: SetStatus with unexpected status: $status";
    return;
  }

  # report status if it has changed
  if ((!defined $hash->{STATUS}) || (!($hash->{STATUS} eq $status)))
  {
    Log3 $name, 5, "KacoPowadorRS232 ($name) - $status";
    $hash->{STATUS} = $status;

    # Update "state" reading consistently with DevIo. Some other
    # values are set by DevIo. Do not create event for the "state"
    # reading.
    if (($status eq "initializing") ||
        ($status eq "initialized") ||
        ($status eq "ready"))
    {
      setReadingsVal($hash, "state", $status, TimeNow());
    }
  }
}

1;

=pod
=item summary    Reads data from a Kaco Powador RS232 interface.
=item summary_DE Liest Daten von einem Kaco Powador RS232 Interface.
=begin html

<a name="KacoPowadorRS232"></a>
<h3>KacoPowadorRS232</h3>

<ul>
  This module reads data from a Kaco Powador RS232 interface.<br>
  <br>
  
  <a name="KacoPowadorRS232_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; KacoPowadorRS232 &lt;serialPort&gt;</code> <br>
    &lt;serialPort&gt; specifies the serial/RS232 connected to solar inverter, e.g. /dev/ttyUSB0."<br>
  </ul>
  <br>
  
  <a name="KacoPowadorRS232_Set"></a>
  <b>Set</b>
  <ul>
    <li>reset &ndash; resets the connection to the solar inverter</li>
  </ul>
  <br>

  <a name="KacoPowadorRS232_Get"></a>
  <b>Get</b>
  <ul>
    <li>no get functionality</li>
  </ul>
  <br>

  <a name="KacoPowadorRS232_Attr"></a>
  <b>Attributes</b>
  <ul>
    <li>no attributes</li>
  </ul>
  <br>
      
  <a name="KacoPowadorRS232_Readings"></a>
  <b>Readings</b>
  <ul>
    <li>power &ndash; unit: W</li>
    <li>energyToday &ndash; accumulated output energy today, unit: Wh</li>
    <li>temperature &ndash; inside the inverter, unit: degrees Celsius</li>
    <li>mode &ndash; The current operation mode of the solar inverter. Text in German language.</li>
  </ul>
  <br>

</ul>

=end html
=cut
