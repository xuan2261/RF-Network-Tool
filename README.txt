RF & NETWORK DIAGNOSTIC TOOL - PORTABLE v1.5.3 RUNTIME INTEGRITY
================================================================

MUC DICH
- Cong cu portable nhe cho Windows, khong can cai dat.
- PING nhieu IP/hostname co ten goi nho va luu lai sau khi mo lai.
- RF/RJ45 UDP: nghe goi UDP, hien TEXT/HEX, RSSI/SNR neu payload co du lieu phu hop.
- NETWORK SCAN: FAST/BALANCED/DEEP, ICMP bat dong bo + Active ARP + Windows Neighbor IPv4 + snapshot IPv6 NDP thu dong + name discovery.
- Device Details: thong tin mang, lich su, Discovery Evidence va common open TCP ports.
- MONITORING: theo doi lien tuc RF/GPS/Jetson/router/switch bang persistent Ping Worker, khong khoa UI.

YEU CAU
- Windows 10/11 (Windows PowerShell 5.1, .NET Framework 4.8/WinForms).
- Mot so discovery/phat hien ten phu thuoc cau hinh firewall, AP isolation, VLAN, DNS/mDNS/SSDP cua thiet bi.
- Active ARP chi phat hien truc tiep host IPv4 on-link; khac subnet/VLAN can Layer-3/routing discovery.

CHAY LAN DAU
1. Giai nen toan bo ZIP vao mot thu muc thuong, vi du D:\Tools\RF-Network-Tool.
2. Chay RUN-DIAGNOSTIC.cmd. Ket qua mong doi: Diagnostic: PASS.
3. Neu PASS, dung START-RF-NETWORK-TOOL.vbs de mo GUI khong giu cua so CMD.
4. Neu dang dung FULL PROJECT, co the chay RUN-TESTS.cmd de kiem tra Windows integration.

TAB PING - v1.5.3
- Them IP/hostname, tool tao ten mac dinh Default N; double-click/F2 o Name de sua.
- Luu schemaVersion 2 vao RF-Network-Tool.targets.json; tu migrate du lieu cu.
- Moi target = mot row DataGridView, tranh loi layout/don nhieu IP vao mot hang cua implementation cu.
- Ping mot target, Ping tat ca va Ping RF deu di qua RF-Network-Tool-PingWorker.ps1.
- Worker dung SendPingAsync va bounded concurrency, GUI chi enqueue/poll ket qua, khong Ping.Send dong bo tren UI thread.

TAB RF / RJ45
- Chon adapter, RF IP va UDP local port; Start UDP / Stop UDP.
- Payload hien TEXT/HEX; RSSI/SNR chi hien neu parser tim duoc field tu packet.
- Ping RF chay nen qua Ping Worker nen van co the chuyen tab/resize trong luc ping.

TAB NETWORK SCAN
- FAST: uu tien ICMP nhanh + ARP/Neighbor, name discovery ngan.
- BALANCED: mac dinh, co ICMP retry va discovery vua phai.
- DEEP: timeout/discovery dai hon cho mang embedded/RF/GPS/Jetson.
- ICMP responder -> Online. Khong tra ICMP nhung tra ARP -> L2 Seen.
- IPv6 NDP: chi doc neighbor cache tren dung interface; khong brute-force/khong sinh dai IPv6 va khong mutate neighbor table.
- Route-aware: tuy chon (mac dinh OFF). Khi bat, primary CIDR van duoc giu; tool chi doc Get-NetRoute tren dung InterfaceIndex va tu dong them toi da 4 RFC1918 subnet /24..30, moi subnet <=254 host, tong unique target <=1024. Neu co subnet tu dong, GUI hien danh sach CIDR va hoi xac nhan truoc khi scan.
- Route mac dinh/public/sai interface/qua rong/host-only/trung lap bi bo qua. Neu doc route table loi, scan fail-soft ve primary CIDR.
- Worker scan nam ngoai UI process callback path; UI poll state theo runId/session de loai stale state.
- Name discovery dung DNS/PTR, ping -a/NetBIOS (tuy profile), mDNS/DNS-SD, SSDP/UPnP va cache evidence.

TAB MONITORING - v1.5.3
- Nguon target: danh sach da luu trong tab PING. Nhan Dong bo tu PING neu can cap nhat ten.
- Moi target co ON/OFF rieng, interval 1/2/5/10/30 giay va tuy chon ALERT.
- Metrics: STATUS, NOW, MIN, AVG, MAX, LOSS, UPTIME, DOWNTIME, OUTAGES, LAST CHANGE.
- Tat ca ICMP monitoring dung cung persistent RF-Network-Tool-PingWorker.ps1; UI chi enqueue/poll ket qua.
- Ping thu cong co request-freshness guard; ket qua monitoring cu khong duoc ghi de ket qua manual moi.
- ALERT dung am bao + balloon tooltip non-modal, khong dung MessageBox chan UI.
- Cau hinh luu vao RF-Network-Tool.monitoring.json. Timeline transition giu toi da 500 event trong RF-Network-Tool.monitoring-history.json.
- Thong ke latency/loss/uptime/downtime la cua phien hien tai; timeline transition la persistent.
- Monitoring dua tren ICMP. Thiet bi chan ICMP van co the L2 Seen trong NETWORK SCAN nhung OFFLINE trong MONITORING.

DISCOVERY EVIDENCE
- PASS: co bang chung truc tiep.
- NO RESPONSE: da probe nhung khong co response trong cua so thoi gian.
- NOT OBSERVED: khong thay announcement/response; khong co nghia giao thuc chac chan khong ton tai.
- SKIPPED: profile/logic bo qua probe do.
- INFO: metadata/decision cua engine.
- ERROR: probe gap loi co kiem soat.

OPEN PORTS / DEEP ANALYSIS
- Phan tich sau chay background trong RF-Network-Tool-TaskWorker.ps1.
- Common TCP services duoc probe gioi han (FTP/SSH/Telnet/DNS/HTTP/HTTPS/SMB/RTSP/IPP/MQTT/RDP/VNC/HTTP-alt/Printer...).
- Day khong phai full 1-65535 port scanner.
- HTTP/UPnP LAN probe khong dung system proxy; redirect bi tat; XML DTD bi cam va response bi gioi han.

IEEE OUI - v1.5.3
- Nhan Update IEEE OUI de tai registry tu standards-oui.ieee.org qua HTTPS trong background Task Worker.
- Worker kiem scheme/host sau redirect, gioi han kich thuoc va tao compact cache:
  RF-Network-Tool.oui-prefix-cache.v1.tsv
- GUI nap compact cache theo chunk nho qua timer, tranh Import-Csv lon tren UI thread.
- Randomized/locally-administered MAC khong bi gan vendor IEEE gia.
- KnownOui chi la offline fallback; IEEE cache uu tien cao hon.

RUNTIME HARDENING
- Single-instance lock tren DataDir.
- sessionId/runId cho Scan/Discovery/Ping/Task IPC.
- Parent PID + process StartTime identity cho worker moi, giam rui ro PID reuse.
- Heartbeat/watchdog cho Ping/OUI/Deep/Scan/Discovery.
- Atomic JSON/cache writes bang temp unique va replace/move.
- Khong con Application.DoEvents() trong runtime.
- Global WinForms exception boundary + startup/runtime logs.
- Neu thu muc tool khong ghi duoc, DataDir fallback sang %%LOCALAPPDATA%%\RF-Network-Tool.

FILE DU LIEU / LOG TU TAO
- RF-Network-Tool.targets.json
- RF-Network-Tool.device-history.json
- RF-Network-Tool.scan-history.json
- RF-Network-Tool.monitoring.json
- RF-Network-Tool.monitoring-history.json
- RF-Network-Tool.oui-prefix-cache.v1.tsv
- oui-data\oui.csv, mam.csv, oui36.csv
- logs\startup-*.log, runtime-*.log, scan-*.log va worker logs

XU LY LOI
- Startup: chay RUN-DIAGNOSTIC.cmd va xem logs\startup-*.log.
- Runtime/worker: xem logs\runtime-*.log va scan/worker log gan nhat.
- Scan bo sot host: thu BALANCED/DEEP, kiem subnet/VLAN/AP isolation; host chặn ICMP van co the xuat hien L2 Seen neu ARP duoc.
- Nhieu private subnet/VLAN co route rieng: bat Route-aware. Route /23 hoac rong hon khong duoc auto-expand; hay nhap primary CIDR hep hon neu can.
- Ten thiet bi trong router nhung tool khong thay: router co the chi luu DHCP client-name noi bo va khong expose qua DNS/mDNS/SSDP/NetBIOS.
- Windows Script Host 800A0408: START-RF-NETWORK-TOOL.vbs trong release phai ASCII/no-BOM.

CAC FILE PORTABLE BAT BUOC
- START-RF-NETWORK-TOOL.vbs
- RUN-PORTABLE.cmd
- RUN-DIAGNOSTIC.cmd
- RF-Network-Tool-Launcher.ps1
- RF-Network-Tool-Portable.ps1
- RF-Network-Tool-ScanWorker.ps1
- RF-Network-Tool-RoutePlanner.ps1
- RF-Network-Tool-DiscoveryWorker.ps1
- RF-Network-Tool-PingWorker.ps1
- RF-Network-Tool-TaskWorker.ps1
- README.txt
- SHA256.txt

FULL PROJECT con co plans/, tests/, audit/QA/code-review/release docs de tiep tuc phat trien.

VERIFICATION
- Linux-side static/deterministic/source/package tests duoc ghi trong QA_REPORT_v1.4.0.md.
- Windows runtime acceptance chi PASS sau khi RUN-DIAGNOSTIC.cmd + RUN-TESTS.cmd + smoke test tren Windows PowerShell 5.1/WinForms deu PASS.

V1.5.3 RELEASE VERIFICATION NOTE
- Hosted CI Windows Server 2022/2025: PASS.
- Windows 10 interactive physical Full qualification: NOT RUN / NOT VERIFIED tai thoi diem release.
- Physical evidence v1.5.2 khong duoc tai su dung de ket luan physical PASS cho v1.5.3.
