function New-Identity([string]$Destination, [bool]$Abyss) {
  $values = if ($Abyss) {
    @{
      APP_PRODUCT_IS_ABYSS = 'true'; APP_PRODUCT = 'Abyss'; APP_DATA_FOLDER = 'abyss'
      APP_REGISTRY_ROOT = 'Software\\Abyss'; APP_MUTEX = 'Local\\Abyss.SingleInstance'
      APP_OPEN_PROPERTY = 'Abyss.OpenRequests'; APP_LOGIN_PROFILE = 'Abyss-Login'
      APP_WER_NAME = 'abyss_wer'; APP_IMPELLER_VARIABLE = 'ABYSS_IMPELLER'
      APP_PERF_VARIABLE = 'ABYSS_PERF_SCENARIOS'; APP_CLIPBOARD_FORMAT = 'Abyss Markdown'
      APP_LOGIN_WINDOW_CLASS = 'ABYSS_LOGIN_WINDOW'; APP_CLI_FLAG = '--abyss-cli'
      APP_AGENT_FLAG = '--abyss-agent'; APP_LINK_FLAG = '--abyss-link'; APP_OPEN_DATA = '0x41425953'
    }
  } else {
    @{
      APP_PRODUCT_IS_ABYSS = 'false'; APP_PRODUCT = 'BaoCode'; APP_DATA_FOLDER = 'baocode'
      APP_REGISTRY_ROOT = 'Software\\BaoCode'; APP_MUTEX = 'Local\\BaoCode.SingleInstance'
      APP_OPEN_PROPERTY = 'BaoCode.OpenRequests'; APP_LOGIN_PROFILE = 'BaoCode-Login'
      APP_WER_NAME = 'baocode_wer'; APP_IMPELLER_VARIABLE = 'BAOCODE_IMPELLER'
      APP_PERF_VARIABLE = 'BAOCODE_PERF_SCENARIOS'; APP_CLIPBOARD_FORMAT = 'BaoCode Markdown'
      APP_LOGIN_WINDOW_CLASS = 'BAOCODE_LOGIN_WINDOW'; APP_CLI_FLAG = '--baocode-cli'
      APP_AGENT_FLAG = '--baocode-agent'; APP_LINK_FLAG = '--baocode-link'; APP_OPEN_DATA = '0x42414F43'
    }
  }
  $contents = [IO.File]::ReadAllText((Join-Path $root 'windows\runner\generated_edition_identity.h.in'))
  foreach ($key in $values.Keys) {
    $contents = $contents.Replace("@$key@", $values[$key])
  }
  if ($contents.Contains('@APP_')) { throw 'Not all identity placeholders were substituted.' }
  [IO.File]::WriteAllText($Destination, $contents, [Text.UTF8Encoding]::new($false))
}
