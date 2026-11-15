<?php
// tests/e2e.sh calls this through httpd -> ProxyPassMatch -> the sidecar's 8501 pool.
session_start();
if (isset($_GET['warn'])) {
    trigger_error('php85-e2e warning', E_USER_WARNING);
}
$_SESSION['n'] = ($_SESSION['n'] ?? 0) + 1;
header('Content-Type: application/json');
echo json_encode([
    'php' => PHP_VERSION,
    'n' => $_SESSION['n'],
    'user' => $_SESSION['user'] ?? null,
    'system_disabled' => !function_exists('system'),
    'upload_max_filesize' => ini_get('upload_max_filesize'),
    'memory_limit' => ini_get('memory_limit'),
    'script' => $_SERVER['SCRIPT_FILENAME'] ?? null,
], JSON_UNESCAPED_SLASHES), "\n";
