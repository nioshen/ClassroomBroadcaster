# ClassroomBroadcaster 設定（一般不用改；修改後重新啟動即生效）
@{
    # 主教師機在教室區網的 IP。'auto' = 自動偵測；多張網卡偵測錯時請直接填，例如 '192.168.10.100'
    ServerIP      = 'auto'

    # [第二教師機用] 主教師機的 IP（第一次執行 teacher2.bat / lite-teacher2.bat 會詢問並自動填入）
    MainServerIP  = ''

    # 學生播放頁的網頁埠：學生開 http://主教師機IP:8080/
    HttpPort      = 8080

    # 限制只有這些 IP 可以推流到「教師 2」頻道。留空 = 區網內任何電腦都可以。例：@('192.168.10.101')
    PublisherIPs  = @()

    # [OBS 版] 啟動時是否自動開啟 OBS 並開始直播
    StartOBS      = $true
    # [OBS 版] OBS 路徑；'auto' = 優先用資料夾內的免安裝版，其次找電腦上已安裝的 OBS
    ObsPath       = 'auto'
    # [OBS 版] OBS 的設定檔與場景名稱（第一次啟動會自動建立 Classroom）
    ObsProfile    = 'Classroom'
    ObsCollection = 'Classroom'

    # [OBS 版] 執行 stop.bat 時是否一併關閉 OBS
    StopOBSOnExit = $false

    # [OBS 版] 啟動後是否在本機開一個預覽視窗（確認學生看到的畫面）
    OpenPreview   = $true
}
