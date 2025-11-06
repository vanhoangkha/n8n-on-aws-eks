# Changelog

All notable changes to the n8n-on-aws-eks project will be documented in this file.

## [2.0.0] - 2024-12-01

### Added

#### Production-Ready Features
- **Persistent Storage**: Added PersistentVolumeClaims for PostgreSQL (20GB) and n8n (10GB) to prevent data loss
- **Storage Class**: Created gp3 storage class configuration for AWS EBS volumes
- **Network Policies**: Implemented Kubernetes NetworkPolicy for pod-to-pod communication security
- **Horizontal Pod Autoscaling**: Added HPA configuration for automatic scaling based on CPU (70%) and memory (80%)
- **Ingress Controller**: Added ALB Ingress configuration for HTTPS support and custom domains
- **Automated Backups**: Implemented CronJob for daily database backups at 2 AM UTC
- **Backup PVC**: Added 50GB PVC for backup storage with automated cleanup (keeps 7 days)
- **Restore Job**: Created Kubernetes Job for manual database restore operations

#### Enhanced Deployment Script
- Added AWS credentials validation before deployment
- Implemented better error handling and progress messages
- Added NAT gateway configuration for improved reliability
- Created gp3 storage class automatically if not exists
- Added comprehensive status reporting during deployment
- Implemented PVC waiting logic to ensure volumes are ready
- Improved timeout handling for deployments (600s for full initialization)
- Added EBS CSI driver installation with proper IAM role configuration

#### Improved Monitoring
- Enhanced monitor.sh with comprehensive status dashboard
- Added pod details, restarts, and resource usage tracking
- Included persistent volume status checks
- Added recent events display
- Improved error messages and validation
- Added quick command reference for common operations

#### Enhanced Cleanup Script
- Added confirmation prompt to prevent accidental deletion
- Implemented proper namespace deletion before cluster cleanup
- Added orphaned LoadBalancer cleanup
- Better error handling and status reporting
- Graceful handling of already-deleted resources

#### New Utility Scripts
- **backup.sh**: Manual database backup with timestamp
- **restore.sh**: Manual database restore with safety confirmation
- **get-logs.sh**: Quick log access for n8n and postgres pods

### Changed

#### Updated Deployments
- **PostgreSQL**: Updated to use PersistentVolumeClaim instead of emptyDir
- **Memory Resources**: Increased PostgreSQL memory from 512Mi to 1Gi limit
- **Health Probes**: Enhanced liveness and readiness probes with proper timeouts and failure thresholds
- **Storage**: Increased minimum disk size for EKS nodes to 50GB
- **Network**: Changed NAT gateway from Disable to Single for better reliability

#### Improved Security
- Network policies restrict pod communication to required ports only
- Egress policies allow necessary external connections (DNS, HTTPS)
- Added encryption for EBS volumes in EKS configuration

#### Better Resource Management
- Increased PostgreSQL memory to handle larger databases
- Improved health probe configuration to prevent false restarts
- Added proper timeouts for all probes (5-10 seconds)
- Set appropriate failure thresholds (3 attempts)

### Fixed
- Fixed deployment script profile handling (changed default from 'devops' to 'default')
- Fixed NAT gateway configuration for proper internet connectivity
- Improved EBS CSI driver installation with proper error handling
- Fixed PVC creation order in deployment script
- Added proper volume binding mode for StorageClass

### Documentation
- Updated project structure to reflect new files
- Added comprehensive deployment steps
- Included backup and restore procedures
- Documented new security features

## [1.0.0] - 2024-10-01

### Initial Release
- Basic EKS deployment with eksctl
- PostgreSQL 15 deployment with ClusterIP service
- n8n latest deployment with LoadBalancer service
- Basic namespace and resource quotas
- Initial deployment, monitoring, and cleanup scripts
- Network Load Balancer configuration

