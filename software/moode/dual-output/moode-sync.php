<?php
/*
 * moode-sync.php - regenerate moOde's /etc/mpd.conf with the jukebox settings.
 *
 * Run as root by jukebox-moode.sh (install only; the guard never touches MPD
 * state so playback is not interrupted). It:
 *   1. pins the MPD ALSA buffer to 3 s (absorbs player stalls; see the
 *      Volumio package for the full story),
 *   2. regenerates /etc/mpd.conf through moOde's own updMpdConf(), so the
 *      mixer type (null = CamillaDSP fader), output device and buffer stay
 *      consistent with moOde's database.
 *
 * No PHP session is used: the needed state is loaded straight from cfg_system
 * so the WebUI session file is left alone.
 */
error_reporting(E_ALL & ~E_DEPRECATED & ~E_WARNING);
require_once '/var/www/inc/common.php';
require_once '/var/www/inc/alsa.php';
require_once '/var/www/inc/audio.php';
require_once '/var/www/inc/cdsp.php';
require_once '/var/www/inc/mpd.php';
require_once '/var/www/inc/sql.php';

$bufferTime = getenv('JB_MPD_BUFFER_TIME') ?: '3000000';
$dbh = sqlConnect();

// Load cfg_system into $_SESSION exactly like phpSession('load_system')
foreach (sqlRead('cfg_system', $dbh) as $row) {
    if (!str_contains($row['param'], 'RESERVED_')) {
        $_SESSION[$row['param']] = $row['value'];
    }
}

// 1. ALSA buffer (moOde only writes it when != 500000)
sqlUpdate('cfg_mpd', $dbh, 'buffer_time', $bufferTime);
$_SESSION['buffer_time'] = $bufferTime;
echo "mpd buffer_time = $bufferTime us\n";

// 2. Regenerate /etc/mpd.conf with moOde's own code
updMpdConf();
$mixer = sqlQuery("SELECT value FROM cfg_mpd WHERE param='mixer_type'", $dbh)[0]['value'] ?? '?';
$device = sqlQuery("SELECT value FROM cfg_mpd WHERE param='device'", $dbh)[0]['value'] ?? '?';
echo "mpd.conf regenerated (device=$device, mixer_type=$mixer)\n";

// 3. Report the CamillaDSP volume-sync state
if (($mixer ?? '') == 'null' && ($_SESSION['camilladsp'] ?? 'off') != 'off') {
    echo "volume sync: active (CamillaDSP fader)\n";
} else {
    echo "volume sync: off (mixer=$mixer, camilladsp=" . ($_SESSION['camilladsp'] ?? '?') . ")\n";
}
