# minimum-platform

## goal
- deliver a minimal platform that organisations can reuse
- cover base cases of each platform aspects

## ideals
  - platform takes the pain
  - use opensource tools

## monitoring and alerting
  - metrics
  - logs
  - traces
  - rum
  - ui

## identity management
  - users
  - rbac
  - teams
  - products
  - scopes

## resources
  - blob storage
  - blob access
    - rbac

## service management
  - cluster management
    - kubernetes
  - cluster security
    - firewall
  - multiple clusters
    - kubernetes cluster 1
    - kubernetes cluster 2
    - kubernetes cluster 3
    - cluster communication via private endpoint
  - cluster synchronisation
  - cluster access
    - rbac

## service communication
  - event management
    - apache kafka
    - consumer management
    - producer management
  - data validation
    - schema extraction
    - schema management
  - topic access
    - rbac

## data processing
  - data lineage
    - apache airflow
  - data validation
    - schema extraction
    - schema management
  - data transformation
    - apache spark
  - data visualization
    - apache superset
    - power-bi
  - data access
    - rbac
  - data extraction
    - blob
    - events
    - database
      - sql
      - postgres
  - data pushing
    - blob
    - events
    - database
      - mssql
      - postgres

---
Local Kubernetes multi-management-plane setups are documented in:
- [kubernetes-providers/documentation/README.md](kubernetes-providers/documentation/README.md)

