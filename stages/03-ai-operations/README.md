# Stage 3: AI-assisted operations

This stage is intentionally not deployed until Stages 1 and 2 have completed evidence runs.

The model receives only normalized findings. Raw WAF headers, paths, request bodies, User-Agent values, and Shield samples are hashed and retained outside the model prompt. Advisory mode has no operational tools. Later approval-controlled tools may invoke only the existing reconciler and evidence collector with schema-validated parameters.

Autonomous IAM changes, Shield subscription changes, WAF policy-catalogue changes, and teardown are prohibited.
