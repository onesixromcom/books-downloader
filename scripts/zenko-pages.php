<?php

$filename = $argv[1];

$json = json_decode(file_get_contents($filename), true);
if (empty($json['pages'])) {
    return;
}

foreach ($json['pages'] as $page) {
    echo $page['content'] . "\n";
}
