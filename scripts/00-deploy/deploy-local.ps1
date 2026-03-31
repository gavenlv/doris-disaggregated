#!/usr/bin/env pwsh

param(
    [Parameter(Position=0)]
    [ValidateSet("deploy", "minio", "doris", "verify", "test", "info", "cleanup", "help")]
    [string]$Command = "deploy"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$K8sDir = Join-Path (Split-Path $ScriptDir -Parent) "k8s\local"

function Write-Info($message) {
    Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $message
}

function Write-Success($message) {
    Write-Host "[SUCCESS] " -ForegroundColor Green -NoNewline
    Write-Host $message
}

function Write-Warning($message) {
    Write-Host "[WARNING] " -ForegroundColor Yellow -NoNewline
    Write-Host $message
}

function Write-Error($message) {
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $message
}

function Test-Kubectl {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Error "kubectl not found. Please install kubectl first."
        exit 1
    }
    
    try {
        kubectl cluster-info | Out-Null
        Write-Success "Kubernetes cluster is accessible."
    }
    catch {
        Write-Error "Kubernetes cluster not accessible. Please ensure Docker Desktop Kubernetes is running."
        exit 1
    }
}

function Test-DockerDesktop {
    Write-Info "Checking Docker Desktop Kubernetes..."
    
    $context = kubectl config current-context
    if ($context -notlike "*docker-desktop*") {
        Write-Warning "Current context is not docker-desktop: $context"
        Write-Info "Switching to docker-desktop context..."
        try {
            kubectl config use-context docker-desktop | Out-Null
        }
        catch {
            Write-Error "Failed to switch to docker-desktop context."
            exit 1
        }
    }
    
    Write-Success "Using docker-desktop context."
}

function Deploy-Minio {
    Write-Info "Deploying MinIO..."
    
    kubectl apply -f "$K8sDir\00-minio.yaml"
    
    Write-Info "Waiting for MinIO to be ready..."
    try {
        kubectl wait --for=condition=ready pod -l app=minio -n doris --timeout=120s
    }
    catch {
        Write-Warning "MinIO pod not ready within timeout, checking status..."
        kubectl get pods -n doris -l app=minio
    }
    
    Write-Info "Waiting for MinIO setup job..."
    try {
        kubectl wait --for=condition=complete job/minio-setup -n doris --timeout=60s
    }
    catch {
        Write-Warning "MinIO setup job may have already completed."
    }
    
    Write-Success "MinIO deployed successfully."
}

function Deploy-Doris {
    Write-Info "Deploying Doris components..."
    
    kubectl apply -f "$K8sDir\00-storageclass.yaml"
    
    Write-Info "Deploying Frontend..."
    kubectl apply -f "$K8sDir\02-fe.yaml"
    try {
        kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=180s
        Write-Success "Frontend is ready."
    }
    catch {
        Write-Error "Frontend failed to start"
        kubectl describe pod -l app=doris-fe -n doris
        exit 1
    }
    
    Write-Info "Deploying Backend..."
    kubectl apply -f "$K8sDir\03-be.yaml"
    try {
        kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=180s
        Write-Success "Backend is ready."
    }
    catch {
        Write-Error "Backend failed to start"
        kubectl describe pod -l app=doris-be -n doris
        exit 1
    }
    
    Write-Info "Registering Backend to Frontend..."
    $bePod = "doris-fe-0"
    $bePodIP = kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}'
    if ($bePodIP) {
        Write-Info "BE Pod IP: $bePodIP"
        kubectl exec $bePod -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "ALTER SYSTEM ADD BACKEND '${bePodIP}:9050';" 2>&1 | Out-Null
        Start-Sleep -Seconds 10
        $backendStatus = kubectl exec $bePod -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW BACKENDS\G" 2>&1 | Select-String -Pattern "Alive"
        Write-Info "Backend status: $backendStatus"
    }
    else {
        Write-Warning "Could not get BE pod IP, skipping automatic registration."
    }
    
    Write-Success "Doris deployment completed successfully!"
}

function Verify-Deployment {
    Write-Info "Verifying deployment..."
    
    Write-Host ""
    Write-Info "=== Pod Status ==="
    kubectl get pods -n doris -o wide
    
    Write-Host ""
    Write-Info "=== Services ==="
    kubectl get svc -n doris
    
    Write-Host ""
    Write-Info "=== PVC Status ==="
    kubectl get pvc -n doris
    
    Write-Host ""
    Write-Info "=== Component Health ==="
    
    $feReady = kubectl get pod -l app=doris-fe -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'
    $beReady = kubectl get pod -l app=doris-be -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'
    $minioReady = kubectl get pod -l app=minio -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'
    
    Write-Host "  MinIO:        " -NoNewline
    if ($minioReady -eq "True") { Write-Host "Ready" -ForegroundColor Green } else { Write-Host "Not Ready" -ForegroundColor Red }
    
    Write-Host "  Frontend:     " -NoNewline
    if ($feReady -eq "True") { Write-Host "Ready" -ForegroundColor Green } else { Write-Host "Not Ready" -ForegroundColor Red }
    
    Write-Host "  Backend:      " -NoNewline
    if ($beReady -eq "True") { Write-Host "Ready" -ForegroundColor Green } else { Write-Host "Not Ready" -ForegroundColor Red }
}

function Test-Doris {
    Write-Info "Testing Doris connectivity..."
    
    Write-Info "Starting port-forward to FE..."
    $pf = Start-Process -FilePath "kubectl" -ArgumentList "port-forward", "svc/doris-fe", "9030:9030", "-n", "doris" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 5
    
    Write-Info "Testing MySQL connection..."
    
    $mysql = Get-Command mysql -ErrorAction SilentlyContinue
    if ($mysql) {
        try {
            $result = & mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW FRONTENDS;" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "MySQL connection successful!"
                Write-Host $result
            }
        }
        catch {
            Write-Warning "MySQL connection failed: $_"
        }
    }
    else {
        Write-Warning "MySQL client not found, skipping MySQL test."
    }
    
    Write-Info "Testing HTTP API..."
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:8030/api/health" -TimeoutSec 10 -UseBasicParsing
        if ($response.StatusCode -eq 200) {
            Write-Success "HTTP API is accessible!"
        }
    }
    catch {
        Write-Warning "HTTP API test failed: $_"
    }
    
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
    
    Write-Success "Doris connectivity test completed."
}

function Show-AccessInfo {
    Write-Host ""
    Write-Info "=== Access Information ==="
    Write-Host ""
    Write-Host "所有端口转发已在后台运行:"
    Write-Host ""
    Write-Host "MinIO Console:" -ForegroundColor Cyan
    Write-Host "  URL: http://127.0.0.1:9001"
    Write-Host "  User: minioadmin"
    Write-Host "  Password: minioadmin"
    Write-Host ""
    Write-Host "Doris FE (MySQL):" -ForegroundColor Cyan
    Write-Host "  Host: 127.0.0.1:9030"
    Write-Host "  User: root"
    Write-Host "  Password: (空)"
    Write-Host "  Command: mysql -h 127.0.0.1 -P 9030 -u root"
    Write-Host ""
    Write-Host "Doris FE (HTTP):" -ForegroundColor Cyan
    Write-Host "  URL: http://127.0.0.1:8030"
    Write-Host ""
    Write-Host "后台启动端口转发命令:" -ForegroundColor Yellow
    Write-Host "  Start-Process -FilePath 'kubectl' -ArgumentList 'port-forward','-n','doris','svc/doris-fe','9030:9030','8030:8030' -WindowStyle Hidden"
    Write-Host "  Start-Process -FilePath 'kubectl' -ArgumentList 'port-forward','-n','doris','svc/minio','9001:9001' -WindowStyle Hidden"
    Write-Host ""
}

function Cleanup {
    Write-Warning "Cleaning up Doris deployment..."
    kubectl delete namespace doris --ignore-not-found=true
    Write-Success "Cleanup completed."
}

function Show-Help {
    Write-Host "Doris Local Deployment Script for Docker Desktop Kubernetes"
    Write-Host ""
    Write-Host "Usage: .\deploy-local.ps1 [command]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  deploy     Deploy MinIO and Doris (default)"
    Write-Host "  minio      Deploy MinIO only"
    Write-Host "  doris      Deploy Doris components only"
    Write-Host "  verify     Verify deployment status"
    Write-Host "  test       Test Doris connectivity"
    Write-Host "  info       Show access information"
    Write-Host "  cleanup    Remove all resources"
    Write-Host "  help       Show this help message"
    Write-Host ""
    Write-Host "Prerequisites:"
    Write-Host "  - Docker Desktop with Kubernetes enabled"
    Write-Host "  - kubectl configured"
    Write-Host ""
}

switch ($Command) {
    "deploy" {
        Test-Kubectl
        Test-DockerDesktop
        Deploy-Minio
        Deploy-Doris
        Verify-Deployment
        
        Write-Info "Starting port-forwards in background..."
        Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/doris-fe","9030:9030","8030:8030" -WindowStyle Hidden
        Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/minio","9001:9001" -WindowStyle Hidden
        Start-Sleep -Seconds 2
        
        Show-AccessInfo
    }
    "minio" {
        Test-Kubectl
        Test-DockerDesktop
        Deploy-Minio
    }
    "doris" {
        Test-Kubectl
        Test-DockerDesktop
        Deploy-Doris
        Verify-Deployment
    }
    "verify" {
        Verify-Deployment
    }
    "test" {
        Test-Doris
    }
    "info" {
        Show-AccessInfo
    }
    "cleanup" {
        Cleanup
    }
    "help" {
        Show-Help
    }
}
