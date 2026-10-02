<#
    レコードの解析と統計の高速版 (C#)。

    PowerShell のループは 1 レコードあたり数 us かかり、16MB (約 100 万レコード) のファイルでは
    解析・統計だけで数秒～十数秒、画面が止まる。同じ処理を C# で行うと数十 ms で終わる。

    - C# のソースはこのファイルに埋め込んだ固定の文字列だけを使う (外部の入力からコードを作らない)
    - 初めて使うときに Add-Type でコンパイルする (モジュールの読み込みは遅くしない)
    - 制約付き言語モード (AppLocker / WDAC) などで Add-Type が使えない場合は $false を返し、
      呼び出し側は PowerShell 版の処理を使う (結果は同じ。テストで一致を確認している)
    - 型名に版番号を付ける。ソースを変えたら版番号も上げること (同じプロセスでは同名の型を作り直せないため)
#>

$script:NCLogNativeSource = @'
using System;

namespace NCLogToolsNative.V1
{
    public sealed class DecodedRecords
    {
        public double[] Value40 { get; set; }
        public double[] Value21 { get; set; }
        public double[] Plot40 { get; set; }
        public double[] Plot21 { get; set; }
        public bool[] Valid { get; set; }
        public int RecordCount { get; set; }
        public int TrailingBytes { get; set; }
        public int InvalidCount { get; set; }
    }

    public sealed class ValueStatistics
    {
        public long Count { get; set; }
        public double Minimum { get; set; }
        public double Maximum { get; set; }
        public double Average { get; set; }
        public double StdDev { get; set; }
    }

    public static class RecordDecoder
    {
        // ADD_40_0 = UInt16 (W)、ADD_21_0 = Double / divisor (mm/min)。リトルエンディアン前提 (呼び出し側で確認済み)
        public static DecodedRecords Decode(byte[] bytes, int headerSize, int recordSize,
            int value40Offset, int value21Offset, double divisor)
        {
            if (bytes == null) throw new ArgumentNullException("bytes");
            if (headerSize < 0 || recordSize <= 0 || value40Offset < 0 || value21Offset < 0 ||
                value40Offset + 2 > recordSize || value21Offset + 8 > recordSize)
            {
                throw new ArgumentException("レコードレイアウトが不正です。");
            }

            long dataLength = Math.Max(0L, (long)bytes.Length - headerSize);
            int count = (int)(dataLength / recordSize);
            var v40 = new double[count];
            var v21 = new double[count];
            var p40 = new double[count];
            var p21 = new double[count];
            var valid = new bool[count];
            int invalid = 0;
            double last40 = 0.0, last21 = 0.0;

            for (int i = 0; i < count; i++)
            {
                int b = headerSize + i * recordSize;
                double a = BitConverter.ToUInt16(bytes, b + value40Offset);
                double w = BitConverter.ToDouble(bytes, b + value21Offset) / divisor;
                v40[i] = a;
                v21[i] = w;
                if (!double.IsNaN(w) && !double.IsInfinity(w))
                {
                    valid[i] = true;
                    last40 = a;
                    last21 = w;
                }
                else
                {
                    invalid++;
                }
                p40[i] = last40;
                p21[i] = last21;
            }

            return new DecodedRecords
            {
                Value40 = v40, Value21 = v21, Plot40 = p40, Plot21 = p21, Valid = valid,
                RecordCount = count, TrailingBytes = (int)(dataLength % recordSize), InvalidCount = invalid
            };
        }

        // Welford 法。valid が null なら有限値すべてが対象。StdDev は母標準偏差
        public static ValueStatistics Measure(double[] values, bool[] valid)
        {
            if (values == null) throw new ArgumentNullException("values");
            if (valid != null && valid.Length != values.Length)
            {
                throw new ArgumentException("Value と Valid の件数が一致しません。");
            }

            long n = 0;
            double mean = 0.0, m2 = 0.0;
            double min = double.PositiveInfinity, max = double.NegativeInfinity;
            for (int i = 0; i < values.Length; i++)
            {
                double x = values[i];
                if (valid != null) { if (!valid[i]) continue; }
                else if (double.IsNaN(x) || double.IsInfinity(x)) { continue; }
                n++;
                double delta = x - mean;
                mean += delta / n;
                m2 += delta * (x - mean);
                if (x < min) min = x;
                if (x > max) max = x;
            }

            if (n == 0) return new ValueStatistics { Count = 0 };
            return new ValueStatistics { Count = n, Minimum = min, Maximum = max, Average = mean, StdDev = Math.Sqrt(m2 / n) };
        }

        // CSV を書く (Export-NCLogValue -Format CSV と同じ内容)。有効レコードだけを書き、書いた件数を返す
        //   "SourceFile","RecordNumber","Value40","Value21"
        //   "C:\Logs\a.BIN","0","2000","1000.5"
        // 数値は InvariantCulture の最短表記 (PowerShell の ConvertTo-Csv と同じ)
        public static int WriteCsv(System.IO.TextWriter writer, string sourceFile, double[] value40, double[] value21, bool[] valid)
        {
            if (writer == null) throw new ArgumentNullException("writer");
            if (value40 == null || value21 == null || valid == null) throw new ArgumentNullException("value40");
            if (value40.Length != value21.Length || value40.Length != valid.Length)
            {
                throw new ArgumentException("Value40 / Value21 / Valid の件数が一致しません。");
            }

            var ic = System.Globalization.CultureInfo.InvariantCulture;
            string source = "\"" + (sourceFile ?? string.Empty).Replace("\"", "\"\"") + "\",\"";
            writer.WriteLine("\"SourceFile\",\"RecordNumber\",\"Value40\",\"Value21\"");
            int written = 0;
            for (int i = 0; i < value40.Length; i++)
            {
                if (!valid[i]) continue;
                writer.Write(source);
                writer.Write(i.ToString(ic));
                writer.Write("\",\"");
                writer.Write(value40[i].ToString(ic));
                writer.Write("\",\"");
                writer.Write(value21[i].ToString(ic));
                writer.WriteLine("\"");
                written++;
            }
            return written;
        }

        // グラフ用: values[start..start+count-1] の最小値と最大値を { min, max } で返す
        public static double[] MinMax(double[] values, int start, int count)
        {
            if (values == null) throw new ArgumentNullException("values");
            if (start < 0 || count <= 0 || start + count > values.Length) throw new ArgumentOutOfRangeException("count");
            double min = values[start], max = values[start];
            for (int i = start + 1; i < start + count; i++)
            {
                double x = values[i];
                if (x < min) min = x;
                if (x > max) max = x;
            }
            return new double[] { min, max };
        }
    }
}
'@

# $null = 未確認、$true = 使える、$false = 使えない (PowerShell 版を使う)
$script:NCLogNativeState = $null
# テスト用: $true にすると C# 版を使わない (PowerShell 版との一致確認に使う)
$script:NCLogNativeDisabled = $false

function Test-NCLogNative {
    <#
    .SYNOPSIS
        C# 版の解析処理が使えるかを返す。初回だけ Add-Type でコンパイルする。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:NCLogNativeDisabled) { return $false }
    if ($null -ne $script:NCLogNativeState) { return $script:NCLogNativeState }

    try {
        if ($null -eq ('NCLogToolsNative.V1.RecordDecoder' -as [type])) {
            Add-Type -TypeDefinition $script:NCLogNativeSource -Language CSharp -ErrorAction Stop
        }
        $script:NCLogNativeState = $true
    }
    catch {
        # 制約付き言語モードなど。遅くはなるが PowerShell 版で同じ結果を出せる
        Write-Verbose "C# 版の解析処理を使えないため、PowerShell 版を使います: $($_.Exception.Message)"
        $script:NCLogNativeState = $false
    }
    $script:NCLogNativeState
}
