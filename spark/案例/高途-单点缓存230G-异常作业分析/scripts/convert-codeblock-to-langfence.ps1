# 把 ```startLine:endLine:relative/path.ext 的 CodeBuddy 行号围栏
# 转换为 ```ext\n// from relative/path.ext L<start>-<end>\n... 形式
# 保留行号信息为注释行（首行），让 GitHub/工蜂/VS Code 都能识别语言名做高亮
#
# 用法: pwsh convert-codeblock-to-langfence.ps1 [-DryRun]

param(
    [string]$Root = 'D:\bigdata\gitproject\bigdata-study\spark\案例\高途-单点缓存230G-异常作业分析',
    [switch]$DryRun
)

# 扩展名 → markdown 语言名 映射
$ExtToLang = @{
    '.scala' = 'scala'
    '.java'  = 'java'
    '.py'    = 'python'
    '.sh'    = 'bash'
    '.bash'  = 'bash'
    '.xml'   = 'xml'
    '.yaml'  = 'yaml'
    '.yml'   = 'yaml'
    '.json'  = 'json'
    '.sql'   = 'sql'
    '.md'    = 'markdown'
    '.go'    = 'go'
    '.kt'    = 'kotlin'
    '.ts'    = 'typescript'
    '.js'    = 'javascript'
    '.cpp'   = 'cpp'
    '.c'     = 'c'
    '.rs'    = 'rust'
    '.toml'  = 'toml'
    '.conf'  = ''
    '.properties' = 'properties'
}

# 注释前缀映射（对应每种语言的单行注释符号）
$LangToComment = @{
    'scala'      = '//'
    'java'       = '//'
    'python'     = '#'
    'bash'       = '#'
    'xml'        = '<!--'
    'yaml'       = '#'
    'json'       = '//'
    'sql'        = '--'
    'markdown'   = '<!--'
    'go'         = '//'
    'kotlin'     = '//'
    'typescript' = '//'
    'javascript' = '//'
    'cpp'        = '//'
    'c'          = '//'
    'rust'       = '//'
    'toml'       = '#'
    'properties' = '#'
    ''           = '#'
}
$XmlEnd = ' -->'

$total = 0
$converted = 0

Get-ChildItem -Path $Root -Recurse -File -Include *.md | ForEach-Object {
    $file = $_.FullName
    $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)
    $newLines = New-Object System.Collections.Generic.List[string]
    $changed = $false
    $localCount = 0

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        # 匹配 ```start:end:path
        if ($line -match '^```(\d+):(\d+):(.+)$') {
            $total++
            $localCount++
            $start = $Matches[1]
            $end = $Matches[2]
            $path = $Matches[3].Trim()
            $ext = [System.IO.Path]::GetExtension($path).ToLower()

            if ($ExtToLang.ContainsKey($ext)) {
                $lang = $ExtToLang[$ext]
                $cmt = $LangToComment[$lang]
                if ($lang -eq 'xml' -or $lang -eq 'markdown') {
                    $newLines.Add("``````$lang")
                    $newLines.Add("$cmt from $path L$start-$end$XmlEnd")
                } else {
                    $newLines.Add("``````$lang")
                    $newLines.Add("$cmt from $path L$start-$end")
                }
                $converted++
                $changed = $true
            } else {
                # 未知扩展，原样保留
                $newLines.Add($line)
            }
        } else {
            $newLines.Add($line)
        }
    }

    if ($changed) {
        Write-Host "[$localCount blocks] $file" -ForegroundColor Cyan
        if (-not $DryRun) {
            # 备份
            $bak = "$file.bak"
            if (-not (Test-Path $bak)) {
                Copy-Item $file $bak -Force
            }
            # 写回
            [System.IO.File]::WriteAllLines($file, $newLines, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Yellow
Write-Host "Total blocks scanned: $total"
Write-Host "Converted:            $converted"
if ($DryRun) {
    Write-Host "(DryRun mode, no files were modified)" -ForegroundColor Yellow
} else {
    Write-Host "(Backups: each file has a .bak alongside)" -ForegroundColor Green
}
