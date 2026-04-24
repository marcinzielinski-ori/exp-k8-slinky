source ./.impacket-env/bin/activate
.impacket-env/bin/psexec.py marci@192.168.68.117 "powershell.exe -Command \"Get-Service -Name 'sshd'\"" 
.impacket-env/bin/psexec.py marci@192.168.68.117 "powershell.exe -Command \"Start-Service -Name 'sshd'\""
