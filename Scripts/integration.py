#!/usr/bin/env python3
"""Run the suite against an isolated OpenSSH daemon; never touches system sshd."""
import argparse, os, pathlib, signal, socket, subprocess, sys, time

parser=argparse.ArgumentParser()
parser.add_argument('--docker',action='store_true',help='Use the Linux OpenSSH fixture instead of macOS sshd')
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
fixture=root/'.build/integration'
fixture.mkdir(parents=True,exist_ok=True)
os.chmod(fixture,0o700)
for name,kind,phrase,pem in [('host_key','ed25519','',False),('client_key','ed25519','',False),('rsa_key','rsa','',False),('encrypted_key','ed25519','fixture-passphrase',False),('pem_key','rsa','',True),('encrypted_rsa_key','rsa','fixture-passphrase',False),('encrypted_pem_key','rsa','fixture-passphrase',True)]:
    path=fixture/name
    if not path.exists():
        cmd=['ssh-keygen','-q','-t',kind,'-N',phrase,'-f',str(path)]
        if pem: cmd+=['-m','PEM']
        subprocess.run(cmd,check=True)
authorized=fixture/'authorized_keys'
authorized.write_text(''.join((fixture/(name+'.pub')).read_text() for name in ['client_key','rsa_key','encrypted_key','pem_key','encrypted_rsa_key','encrypted_pem_key']))
os.chmod(authorized,0o600)
username='macxterm' if args.docker else os.environ.get('USER','')
if not username: sys.exit('USER is not available')
config=fixture/'sshd_config'
config.write_text(f'''Port 22337
ListenAddress {'0.0.0.0' if args.docker else '127.0.0.1'}
HostKey {fixture}/host_key
PidFile {fixture}/sshd.pid
AuthorizedKeysFile {fixture}/authorized_keys
StrictModes no
PasswordAuthentication {'yes' if args.docker else 'no'}
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {username}
AllowTcpForwarding yes
GatewayPorts clientspecified
Subsystem sftp internal-sftp
LogLevel VERBOSE
''')
for port in [22337,22338,22339,22340,22341]:
    with socket.socket() as sock:
        try: sock.bind(('127.0.0.1',port))
        except OSError: sys.exit(f'Port {port} is in use. Stop that fixture or choose a clean test environment.')
processes=[]; container=None; logs=[]
try:
    if args.docker:
        subprocess.run(['docker','build','--build-arg',f'TEST_UID={os.getuid()}','-t','macxterm-openssh-fixture',str(root/'IntegrationTest')],check=True)
        container=subprocess.check_output(['docker','run','--rm','-d','-p','127.0.0.1:22337:22337','-p','127.0.0.1:22340:22340','-v',f'{root}:{root}','macxterm-openssh-fixture','/usr/sbin/sshd','-D','-e','-f',str(config)],text=True).strip()
    else:
        subprocess.run(['/usr/sbin/sshd','-t','-f',str(config)],check=True)
        log=open(fixture/'sshd.log','w'); logs.append(log)
        processes.append(subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log,start_new_session=True))
    log=open(fixture/'http.log','w'); logs.append(log)
    processes.append(subprocess.Popen([sys.executable,str(root/'IntegrationTest/echo_server.py')],stdout=log,stderr=log,start_new_session=True))
    for port in [22337,22338]:
        for attempt in range(50):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=0.1): break
            except OSError: time.sleep(0.1)
        else: raise RuntimeError(f'Fixture port {port} did not start; inspect {fixture}')
    env={**os.environ,'MACXTERM_INTEGRATION':'1','MACXTERM_FIXTURE':str(fixture),'MACXTERM_SSH_USER':username}
    if args.docker: env['MACXTERM_DOCKER']='1'
    result=subprocess.run([str(root/'Scripts/test.sh')],cwd=root,env=env)
    exit_code=result.returncode
finally:
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL); process.wait()
    if container: subprocess.run(['docker','stop',container],stdout=subprocess.DEVNULL,check=False)
    for log in logs: log.close()
sys.exit(exit_code)
