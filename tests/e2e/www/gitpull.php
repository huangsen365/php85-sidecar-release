<?php
// Stands in for /var/www/gitpull.php, which must stay on the old pool when a site moves to 8.5.
echo json_encode(['memory_limit' => ini_get('memory_limit')]), "\n";
