<?php

$filename = $argv[1];

$result = [];
$json = json_decode(file_get_contents($filename), true);

foreach ($json as $chapter) {
    $result[] = $chapter['id'];
}

sort($result);
foreach ($result as $item) {
    echo $item . "\n";
}
