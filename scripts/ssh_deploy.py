"""Deploy HAP to phone via MSI SSH bridge"""
import paramiko
import sys
import os

MSI_HOST = '10.8.0.2'
MSI_USER = 'liuhongjie'
# Also try: hongjie
MSI_PASS = 'Ljm040628'
PHONE_ADDR = '192.168.137.188:34999'

HAP_LOCAL = r'C:\Users\Liuho\ClawdbotHarmony\entry\build\default\outputs\default\entry-default-signed.hap'
HAP_REMOTE = '/tmp/entry-default-signed.hap'
HAP_DEVICE = '/data/local/tmp/entry-default-signed.hap'

def run():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'deploy'

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print(f'Connecting to {MSI_USER}@{MSI_HOST}...')
    ssh.connect(MSI_HOST, username=MSI_USER, password=MSI_PASS, timeout=30)
    print('Connected.')

    if cmd == 'deploy':
        # Step 1: SCP the HAP file
        print(f'Uploading HAP ({os.path.getsize(HAP_LOCAL) // 1024 // 1024}MB)...')
        sftp = ssh.open_sftp()
        sftp.put(HAP_LOCAL, HAP_REMOTE)
        sftp.close()
        print('Upload done.')

        # Step 2: Connect hdc to phone
        print(f'Connecting hdc to {PHONE_ADDR}...')
        stdin, stdout, stderr = ssh.exec_command(f'hdc tconn {PHONE_ADDR}', timeout=10)
        print(stdout.read().decode().strip())

        # Step 3: Send HAP to device
        print('Sending HAP to device...')
        stdin, stdout, stderr = ssh.exec_command(
            f'hdc file send {HAP_REMOTE} {HAP_DEVICE}', timeout=60)
        print(stdout.read().decode().strip())

        # Step 4: Install
        print('Installing...')
        stdin, stdout, stderr = ssh.exec_command(
            f'hdc shell bm install -p {HAP_DEVICE}', timeout=30)
        out = stdout.read().decode().strip()
        err = stderr.read().decode().strip()
        print(out)
        if err:
            print(f'STDERR: {err}')

    elif cmd == 'log':
        # Grab hilog
        tag = sys.argv[2] if len(sys.argv) > 2 else 'ClawdBot'
        print(f'Fetching logs (tag={tag})...')
        stdin, stdout, stderr = ssh.exec_command(
            f'hdc shell hilog -T {tag} -x 2>/dev/null || hdc shell hilog | grep -i {tag}',
            timeout=15)
        print(stdout.read().decode()[:8000])

    elif cmd == 'cmd':
        # Run arbitrary hdc command
        hdc_cmd = ' '.join(sys.argv[2:])
        print(f'Running: hdc {hdc_cmd}')
        stdin, stdout, stderr = ssh.exec_command(f'hdc {hdc_cmd}', timeout=30)
        print(stdout.read().decode().strip())
        err = stderr.read().decode().strip()
        if err:
            print(f'STDERR: {err}')

    elif cmd == 'hilog':
        # Stream hilog for a few seconds
        duration = sys.argv[2] if len(sys.argv) > 2 else '5'
        print(f'Streaming hilog for {duration}s...')
        stdin, stdout, stderr = ssh.exec_command(
            f'timeout {duration} hdc shell hilog 2>/dev/null', timeout=int(duration) + 5)
        print(stdout.read().decode()[:20000])

    ssh.close()
    print('Done.')

if __name__ == '__main__':
    run()
