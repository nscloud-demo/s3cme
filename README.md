# s3cme

Sample Go app repo with test and release pipelines optimized for software supply chain security (S3C). Includes Terraform setup for Artifact Registry and KMS on GCP with [OpenID Connect](https://openid.net/connect/) (OIDC), so no need for service account keys or GitHub secrets. 

![](images/workflow.png)

* [Repo Usage](#usage)
* [Provenance Verification](#provenance-verification)
  * [Manual](#manual)
  * [In Cluster](#in-cluster)

What's in the included workflow pipelines:

* `on-push` - PR qualification
  * Static code vulnerability scan using [trivy](https://github.com/aquasecurity/trivy)
  * Repo security alerts based on sarif reports CodeQL scans
* `on-tag` Release (container image build)
  * Image build/push using [ko](https://github.com/ko-build/ko) (includes SBOM generation)
  * Image vulnerability scan using [trivy](https://github.com/aquasecurity/trivy) with max severity checks parameter
  * Image signing using [KMS key](https://cloud.google.com/security-key-management) and attestation using [cosign](https://github.com/sigstore/cosign)
  * SLSA provenance generation using [slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator)
  * SLSA provenance verification using [cosign](https://github.com/sigstore/cosign) based on CUE policy
* `on-schedule` - Repo hygiene
  * Semantic code analysis using CodeQL (every 4 hours)

## Repo Usage 

Use this template to create a new repo (click the green button and follow the wizard)

![](images/template.png)

When done, clone your new repo locally, and navigate into it

```shell
git clone git@github.com:$GIT_HUB_USERNAME/$REPO_NAME.git
cd $REPO_NAME
```

Initialize your new repo. This will update all the references to your newly clone GitHub repository and initialize the Terraform setup.

```shell
tools/init-repo
terraform -chdir=./setup init
```

Apply the Terraform configuration to create GCP resources (KMS ring/key, Artifact Registry repo, Workload Identity Pool and the Service Account).

```shell
terraform -chdir=./setup apply
```

When promoted, provide:

   * `project_id` - GCP project ID
   * `location` - GCP region (e.g. `us-west1`)
   * `git_repo` - The qualified name of your repo (e.g. `username/repo`)
   * `name` - Your application name (e.g. the repo portion from `git_repo`)

When completed, Terraform will output the configuration values.

Update `env` portion of the `conf` job in `.github/workflows/on-tag.yaml` file to the values output by Terraform:

   * `IMG_NAME`
   * `KMS_KEY`
   * `PROVIDER_ID`
   * `REG_URI`
   * `SA_EMAIL`

When completed, commit and push the updates to your repository: 

```shell
git add --all
git commit -m 'repo init'
git push --all
```

> The above push will trigger the `on-push` flow. You can navigate to the `/actions` in your repo to see the status of that pipeline. 

![](images/push.png)

### Trigger release pipeline

The canonical version of the entire repo is stored in [.version](.version) file. Feel free to edit it (by default: `v0.0.1`). When done, trigger the release pipeline:

> If you did edit the version, make sure to commit and push that change to the repo first. You can also use `make tag` to automate the entire process.

```shell
export VERSION=$(cat .version)
git tag -s -m "initial release" $VERSION
git push origin $VERSION
```

### Monitor the pipeline 

Navigate to `/actions` in your repo to see the status of that release pipeline. Wait until all steps (aka jobs) have completed (green). 

> If any steps fail, click on them to see the cause. Fix it, commit/push changes to the repo, and tag a new release to re-trigger the pipeline again.

![](images/tag.png)

### Review produced image

When successfully completed, that pipeline will create an image. Navigate to the Artifact Registry to confirm the image was created. 

https://console.cloud.google.com/artifacts/docker/$PROJECT_ID/$REGION

![](images/registry.png)

The image is the line item tagged with version (e.g. `v0.4.0`). The other two OCI artifacts named with the image digest in the registry are signature (`.sig`) and attestation (`.att`).

You can now take the image digest and query sigstore transparency service (Rekor). Easiest way to do that is to use the Chainguard's [rekor-search-ui](https://github.com/chainguard-dev/rekor-search-ui). Here is the entry for [s3cme v0.4.4](https://rekor.tlog.dev/?hash=sha256:0e07d5c7ec2caaf2643c0e3604687b5a826c4e5a51bc8a26d99edb0979380d7d).

## Provenance Verification  

Whenever you tag a release in the repo and an image is push to the registry, that image has an "attached" attestation in a form of [SLSA provenance (v0.2)](https://slsa.dev/provenance/v0.2). This allows you to trace that image all the way to its source in the repo (including the GitHub Actions that were used to generate it). That ability for verifiable traceability is called provenance. 

### Manual 

To verify the provenance of an image that was generated by the `on-tag` pipeline manually:

```shell
COSIGN_EXPERIMENTAL=1 cosign verify-attestation \
   --type slsaprovenance \
   --policy policy/provenance.cue \
   $IMAGE_DIGEST
```

> The `COSIGN_EXPERIMENTAL` environment variable is necessary to verify the image with the transparency log

The terminal output will include the checks that were executed as part of the validation, as well as information about the subject (URI of the tag ref that triggered that workflow), with its SHA, name, and Ref.

```shell
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - Any certificates were verified against the Fulcio roots.
```

The output will also include JSON, which looks something like this (`payload` abbreviated): 

```json
{
   "payloadType": "application/vnd.in-toto+json",
   "payload": "eyJfdHl...V19fQ==",
   "signatures": [
      {
         "keyid": "",
         "sig": "MEUCIQCl+9dSv9f9wqHTF9D6L1bizNJbrZwYz0oDtjQ1wiqmLwIgE1T1LpwVd5+lOnalkYzNftTup//6H9i6wKDoCNNhpeo="
      }
   ]
}
```

The `payload` field (abbreviated) is the base64 encoded [in-toto statement](https://in-toto.io/) containing the predicate containing the GitHub Actions provenance:

```json
{
    "_type": "https://in-toto.io/Statement/v0.1",
    "predicateType": "https://slsa.dev/provenance/v0.2",
    "subject": [
        {
            "name": "us-west1-docker.pkg.dev/cloudy-s3c/s3cme/s3cme",
            "digest": {
                "sha256": "22080f8082e60e7f3ab745818e59c6f513464de23b53bbd28dc83c4936c27cbc"
            }
        }
    ],
    "predicate": {...}
}
```

### In Cluster

You can also verify the provenance of an image in your Kubernetes cluster.

> This assumes you already configured the sigstore admission controller in your Kubernetes cluster. If not, you can use the provided [tools/demo-cluster](tools/demo-cluster) script to create a cluster and configure sigstore policy-controller.

First, review the [policy/cluster.yaml](policy/cluster.yaml) file, and make sure the glob pattern matches your Artifact Registry (`**` will match any character). You can make this as specific as you want (e.g. any image in the project in specific region)

```yaml
images:
- glob: us-west1-docker.pkg.dev/cloudy-s3c/**
```

Next, check the subject portion of the issuer identity (in this case, the SLSA workflow with the repo tag)

```yaml
identities:
- issuer: https://token.actions.githubusercontent.com
subjectRegExp: "^https://github.com/mchmarny/s3cme/.github/workflows/slsa.yaml@refs/tags/v[0-9]+.[0-9]+.[0-9]+$"
```

Finally, the policy data that checks for `predicateType` on the image should include the content of the same policy ([policy/provenance.cue](policy/provenance.cue)) we've used during the SLSA verification using image release and in the above manual verification process. 

```yaml
policy:
   type: cue
   data: |
     predicateType: "https://slsa.dev/provenance/v0.2"
     ...
```

> Make sure the content is indented correctly

When finished, apply the policy into the cluster:

```shell
kubectl apply -f policy/cluster.yaml
```

To verify SLSA provenance on any namespace in your cluster, add a sigstore inclusion label to that namespace (e.g. `demo`):

```shell
kubectl label ns demo policy.sigstore.dev/include=true
```

Now, you should see an error when deploying images that don't have SLSA attestation created by your release pipeline:

```shell
kubectl run test --image=nginxdemos/hello -n demo
```

Will result in:

```shell
admission webhook "policy.sigstore.dev" denied the request
validation failed: no matching policies: spec.containers[0].image
index.docker.io/nginxdemos/hello@sha256:409564c3a1d1...
```

That policy failed because the image URI doesn't match the images glob we've specified (`glob: us-west1-docker.pkg.dev/cloudy-s3c/s3cme/**`). How about if we try to deploy image that does:

```shell
kubectl run test -n demo --image us-west1-docker.pkg.dev/cloudy-s3c/s3cme/s3cme@sha256:ead1a5b3e83760e304ee449732feaa4a80c76c2c098dccb56e3d3b8926b5509d
```

Now the failure is on the SLSA policy due to lack of verifiable attestations:

```shell
admission webhook "policy.sigstore.dev" denied the request:
validation failed: failed policy: slsa-attestation-image-policy: spec.containers[0].image
us-west1-docker.pkg.dev/cloudy-s3c/s3cme/s3cme@sha256:ead1a5b3e83760e304ee449732feaa4a80c76c2c098dccb56e3d3b8926b5509d 
attestation keyless validation failed for authority authority-0 for us-west1-docker.pkg.dev/cloudy-s3c/s3cme/s3cme@sha256:ead1a5b3e83760e304ee449732feaa4a80c76c2c098dccb56e3d3b8926b5509d: 
no matching attestations:
```

This demonstrates how the policy-controller admission controller enforces [SLSA provenance](https://slsa.dev/provenance/v0.2) policy in your cluster based on verifiable supply-chain metadata from [cosign](https://github.com/sigstore/cosign).

## Disclaimer

This is my personal project and it does not represent my employer. While I do my best to ensure that everything works, I take no responsibility for issues caused by this code.
