# 通过 Twinkle Tray 的命名管道读写显示器 DDC/CI
# 前提：Twinkle Tray 必须运行（任务栏托盘图标可见）
#
# 用法:
#   .\tt.ps1 list                列出显示器
#   .\tt.ps1 get <属性>           读属性（brightness/volume/contrast/...）
#   .\tt.ps1 show <hex> [-low]   读 VCP 码（-low 取低字节）
#   .\tt.ps1 go <hex> <值>        写 VCP 码

if (-not ('TT' -as [type])) {
Add-Type -TypeDefinition @"
using System.IO;
using System.IO.Pipes;
using System.Text;
public class TT {
    public static string Send(string json) {
        using (var p = new NamedPipeClientStream(".", @"twinkle-tray\cmds", PipeDirection.InOut)) {
            p.Connect(5000);
            var e = new UTF8Encoding(false);
            var b = e.GetBytes(json);
            p.Write(b, 0, b.Length);
            p.Flush();
            var ms = new MemoryStream();
            var buf = new byte[8192];
            int n;
            while ((n = p.Read(buf, 0, buf.Length)) > 0) {
                ms.Write(buf, 0, n);
                if (n < buf.Length) break;
            }
            return e.GetString(ms.ToArray());
        }
    }
}
"@
}

function T($type, $extra) {
    $q = @{ type = $type; monitor = '0' }
    if ($extra) { foreach ($k in $extra.Keys) { $q[$k] = $extra[$k] } }
    $json = $q | ConvertTo-Json -Compress
    Write-Output ([TT]::Send($json))
}

switch ($args[0]) {
    'list' {
        T 'list' $null
    }

    'get' {
        T 'get' @{ property = $args[1] }
    }

    'show' {
        T 'refresh' $null | Out-Null
        Start-Sleep -Milliseconds 800
        $v = T 'get' @{ property = 'vcp'; code = $args[1] }
        # 某些厂商把同一个码在两个字节里各写一遍（如 0x1B1B），
        # 低位字节才是真值。加 -low 时只输出低字节。
        if ($args.Count -gt 2) {
            $n = [int]$v
            Write-Output ($n -band 0xFF)
        }
        if ($args.Count -le 2) {
            Write-Output $v
        }
    }

    'go' {
        T 'setvcp' @{ vcp = $args[1]; value = $args[2] }
    }
}
