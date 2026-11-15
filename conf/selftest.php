<?php
// Run by tests/smoke.sh through each pool (SCRIPT_FILENAME=/opt/sidecar/selftest.php); lives outside /var/www,
// so the web never reaches it: httpd only forwards paths under /var/www.
$opcache = function_exists('opcache_get_status') ? opcache_get_status(false) : false;
$session = session_save_path();
header('Content-Type: application/json');
echo json_encode([
    'php' => PHP_VERSION,
    'uid' => posix_getuid(),
    'gid' => posix_getgid(),
    'groups' => posix_getgroups(),
    'tz' => date_default_timezone_get(),
    'opcache' => is_array($opcache) && !empty($opcache['opcache_enabled']),
    'memory_limit' => ini_get('memory_limit'),
    'upload_max_filesize' => ini_get('upload_max_filesize'),
    'disable_functions' => ini_get('disable_functions') !== '',
    'session_save_path' => $session,
    'session_writable' => $session !== '' && is_writable($session),
    'www_readable' => is_readable('/var/www'),
    'tmp_writable' => is_writable(sys_get_temp_dir()),
], JSON_UNESCAPED_SLASHES), "\n";
