apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${POOL_NAME}
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_ADDRESSES}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${ADV_NAME}
  namespace: metallb-system
spec:
  ipAddressPools:
    - ${POOL_NAME}
