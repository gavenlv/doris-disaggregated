param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("deploy", "cleanup", "status", "info", "help")]
    [string]$Command = "deploy"
)

$K8sDir = "$PSScriptRoot\..\k8s\local-disaggregated"

function Write-Info { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Write-Success { param([string]$msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warning { param([string]$msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Error { param([string]$msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Kubectl {
    Write-Info "Checking kubectl..."
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Error "kubectl not found. Please install kubectl first."
        exit 1
    }
    try {
        kubectl cluster-info 2>&1 | Out-Null
        Write-Success "Kubernetes cluster is accessible."
    }
    catch {
        Write-Error "Kubernetes cluster not accessible."
        exit 1
    }
}

function Test-DockerDesktop {
    Write-Info "Checking Docker Desktop Kubernetes..."
    $context = kubectl config current-context
    if ($context -notlike "*docker-desktop*") {
        Write-Warning "Current context: $context"
    }
}

function Deploy-FoundationDB {
    Write-Info "Deploying FoundationDB..."
    kubectl apply -f "$K8sDir\00-foundationdb.yaml"
    kubectl wait --for=condition=ready pod -l app=foundationdb -n doris --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        Write-Error "FoundationDB failed to start"
        kubectl logs -l app=foundationdb -n doris --tail=50
        exit 1
    }
    Write-Success "FoundationDB is ready."
}

function Deploy-Minio {
    Write-Info "Deploying MinIO..."
    kubectl apply -f "$K8sDir\01-minio.yaml"
    kubectl wait --for=condition=ready pod -l app=minio -n doris --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        Write-Error "MinIO failed to start"
        exit 1
    }
    kubectl wait --for=condition=complete job/minio-setup -n doris --timeout=60s
    Write-Success "MinIO is ready."
}

function Deploy-MetaService {
    Write-Info "Deploying Meta Service and Recycler..."
    kubectl apply -f "$K8sDir\02-ms.yaml"
    Write-Info "Waiting for Meta Service to start (this may take a while)..."
    kubectl wait --for=condition=ready pod -l app=doris-ms -n doris --timeout=300s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Meta Service readiness check timed out, checking logs..."
        kubectl logs -l app=doris-ms -n doris --tail=30
    } else {
        Write-Success "Meta Service is ready."
    }
    Start-Sleep -Seconds 5
    kubectl wait --for=condition=ready pod -l app=doris-recycler -n doris --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Recycler readiness check timed out."
    } else {
        Write-Success "Recycler is ready."
    }
}

function Deploy-FE {
    Write-Info "Deploying Frontend (disagg mode)..."
    kubectl apply -f "$K8sDir\03-fe.yaml"
    Write-Info "Waiting for FE to start..."
    kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=300s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "FE readiness check timed out, checking logs..."
        kubectl logs -l app=doris-fe -n doris --tail=30
    } else {
        Write-Success "Frontend is ready."
    }
}

function Deploy-BE {
    Write-Info "Deploying Backend (disagg mode)..."
    kubectl apply -f "$K8sDir\04-be.yaml"
    Write-Info "Waiting for BE to start..."
    kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=300s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "BE readiness check timed out, checking logs..."
        kubectl logs -l app=doris-be -n doris --tail=30
    } else {
        Write-Success "Backend is ready."
    }
}

function Register-Cluster {
    Write-Info "Registering cluster with Meta Service..."
    Start-Sleep -Seconds 10

    Write-Info "Adding FE to Meta Service..."
    $fePodIP = kubectl get pod doris-fe-0 -n doris -o jsonpath='{.status.podIP}' 2>$null
    if ($fePodIP) {
        $addFeBody = @{
            instance_id = "doris_instance"
            cluster = @{
                type = "SQL"
                cluster_name = "RESERVED_CLUSTER_NAME_FOR_SQL_SERVER"
                cluster_id = "RESERVED_CLUSTER_ID_FOR_SQL_SERVER"
                nodes = @(
                    @{
                        cloud_unique_id = "1:doris_instance:cloud_unique_id_fe00"
                        ip = $fePodIP
                        edit_log_port = 9010
                        node_type = "FE_MASTER"
                    }
                )
            }
        } | ConvertTo-Json -Depth 5

        kubectl exec doris-ms-0 -n doris -- curl -sf "http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999" `
            -d $addFeBody 2>$null
        Write-Success "FE registered with Meta Service."
    }

    Write-Info "Adding BE to Meta Service..."
    $bePodIP = kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}' 2>$null
    if ($bePodIP) {
        $addBeBody = @{
            instance_id = "doris_instance"
            cluster = @{
                type = "COMPUTE"
                cluster_name = "cluster_name0"
                cluster_id = "cluster_id0"
                nodes = @(
                    @{
                        cloud_unique_id = "1:doris_instance:cloud_unique_id_be00"
                        ip = $bePodIP
                        heartbeat_port = 9050
                    }
                )
            }
        } | ConvertTo-Json -Depth 5

        kubectl exec doris-ms-0 -n doris -- curl -sf "http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999" `
            -d $addBeBody 2>$null
        Write-Success "BE registered with Meta Service."
    }

    Write-Info "Creating storage vault (MinIO)..."
    $createVaultBody = @{
        instance_id = "doris_instance"
        name = "doris_instance"
        user_id = "admin"
        vault = @{
            obj_info = @{
                ak = "minioadmin"
                sk = "minioadmin"
                bucket = "doris-data"
                prefix = "doris"
                endpoint = "http://minio:9000"
                external_endpoint = "http://minio:9000"
                region = "us-east-1"
                provider = "S3"
            }
        }
    } | ConvertTo-Json -Depth 5

    kubectl exec doris-ms-0 -n doris -- curl -sf "http://127.0.0.1:8080/MetaService/http/create_instance?token=greedisgood9999" `
        -d $createVaultBody 2>$null
    Write-Success "Storage vault registered."
}

function Verify-Deployment {
    Write-Info "Verifying deployment..."
    Write-Host ""
    Write-Host "  Component Status:" -ForegroundColor Cyan

    $fdbReady = kubectl get pod -l app=foundationdb -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>$null
    $minioReady = kubectl get pod -l app=minio -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>$null
    $msReady = kubectl get pod -l app=doris-ms -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>$null
    $reReady = kubectl get pod -l app=doris-recycler -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>$null
    $feReady = kubectl get pod -l app=doris-fe -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>$null
    $beReady = kubectl get pod -l app=doris-be -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>$null

    function Print-Status { param([string]$name, [string]$status)
        Write-Host "  $name " -NoNewline
        if ($status -eq "True") { Write-Host "Ready" -ForegroundColor Green } else { Write-Host "Not Ready ($status)" -ForegroundColor Red }
    }

    Print-Status "FoundationDB    " $fdbReady
    Print-Status "MinIO           " $minioReady
    Print-Status "Meta Service    " $msReady
    Print-Status "Recycler        " $reReady
    Print-Status "Frontend (FE)   " $feReady
    Print-Status "Backend  (BE)   " $beReady
    Write-Host ""
}

function Show-AccessInfo {
    Write-Host ""
    Write-Info "=== Disaggregated Deployment Access ==="
    Write-Host ""
    Write-Host "Doris FE (MySQL):" -ForegroundColor Cyan
    Write-Host "  Host: 127.0.0.1:9030"
    Write-Host "  User: root"
    Write-Host "  Password: (empty)"
    Write-Host "  Command: mysql -h 127.0.0.1 -P 9030 -u root"
    Write-Host ""
    Write-Host "Doris FE (HTTP):" -ForegroundColor Cyan
    Write-Host "  URL: http://127.0.0.1:8030"
    Write-Host ""
    Write-Host "MinIO Console:" -ForegroundColor Cyan
    Write-Host "  URL: http://127.0.0.1:9001"
    Write-Host "  User: minioadmin"
    Write-Host "  Password: minioadmin"
    Write-Host ""
    Write-Host "Meta Service:" -ForegroundColor Cyan
    Write-Host "  Internal: doris-ms:8080"
    Write-Host ""
    Write-Host "Storage Backend:" -ForegroundColor Cyan
    Write-Host "  Type: S3 (MinIO)"
    Write-Host "  Bucket: doris-data"
    Write-Host "  Endpoint: minio:9000"
    Write-Host ""
    Write-Host "Background port-forward commands:" -ForegroundColor Yellow
    Write-Host "  Start-Process -FilePath 'kubectl' -ArgumentList 'port-forward','-n','doris','svc/doris-fe','9030:9030','8030:8030' -WindowStyle Hidden"
    Write-Host "  Start-Process -FilePath 'kubectl' -ArgumentList 'port-forward','-n','doris','svc/minio','9001:9001' -WindowStyle Hidden"
    Write-Host ""
}

function Show-Help {
    Write-Host "Doris Disaggregated Deployment Script for Docker Desktop Kubernetes"
    Write-Host ""
    Write-Host "Usage: .\deploy-disaggregated.ps1 [command]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  deploy    Deploy full disaggregated stack (FDB + MS + FE + BE)"
    Write-Host "  cleanup   Remove all resources"
    Write-Host "  status    Show component status"
    Write-Host "  info      Show access information"
    Write-Host "  help      Show this help message"
    Write-Host ""
    Write-Host "Architecture: FoundationDB -> Meta Service -> FE/BE -> MinIO (S3)"
    Write-Host ""
}

switch ($Command) {
    "deploy" {
        Test-Kubectl
        Test-DockerDesktop
        Deploy-FoundationDB
        Deploy-Minio
        Deploy-MetaService
        Deploy-FE
        Deploy-BE
        Register-Cluster
        Verify-Deployment

        Write-Info "Starting port-forwards in background..."
        Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/doris-fe","9030:9030","8030:8030" -WindowStyle Hidden
        Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/minio","9001:9001" -WindowStyle Hidden
        Start-Sleep -Seconds 2

        Show-AccessInfo
    }
    "cleanup" {
        Write-Warning "Cleaning up Doris disaggregated deployment..."
        Get-Process -Name "kubectl" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*port-forward*" } | Stop-Process -Force 2>$null
        kubectl delete namespace doris --ignore-not-found=true
        Write-Success "Cleanup completed."
    }
    "status" {
        Verify-Deployment
    }
    "info" {
        Show-AccessInfo
    }
    "help" {
        Show-Help
    }
}
