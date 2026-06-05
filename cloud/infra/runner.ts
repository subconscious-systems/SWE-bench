export function createRunner() {
  const instanceType = process.env.INSTANCE_TYPE ?? "m6i.2xlarge";
  const dataVolumeSize = Number(process.env.DATA_VOLUME_GB ?? "500");

  const role = new aws.iam.Role("RunnerRole", {
    assumeRolePolicy: JSON.stringify({
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: { Service: "ec2.amazonaws.com" },
          Action: "sts:AssumeRole",
        },
      ],
    }),
  });

  new aws.iam.RolePolicyAttachment("RunnerSSM", {
    role: role.name,
    policyArn: "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  });

  const instanceProfile = new aws.iam.InstanceProfile("RunnerProfile", {
    role: role.name,
  });

  const securityGroup = new aws.ec2.SecurityGroup("RunnerSG", {
    description: "SWE-bench runner - egress only; access via SSM",
    egress: [
      {
        protocol: "-1",
        fromPort: 0,
        toPort: 0,
        cidrBlocks: ["0.0.0.0/0"],
      },
    ],
  });

  const ami = aws.ec2.getAmiOutput({
    mostRecent: true,
    owners: ["099720109477"],
    filters: [
      {
        name: "name",
        values: ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"],
      },
      {
        name: "architecture",
        values: ["x86_64"],
      },
    ],
  });

  const instance = new aws.ec2.Instance("Runner", {
    instanceType,
    ami: ami.id,
    iamInstanceProfile: instanceProfile.name,
    vpcSecurityGroupIds: [securityGroup.id],
    associatePublicIpAddress: true,
    rootBlockDevice: {
      volumeSize: 100,
      volumeType: "gp3",
      deleteOnTermination: true,
    },
    tags: {
      Name: `swe-bench-runner-${$app.stage}`,
    },
  });

  const dataVolume = new aws.ebs.Volume("RunnerData", {
    availabilityZone: instance.availabilityZone,
    size: dataVolumeSize,
    type: "gp3",
    encrypted: true,
    tags: {
      Name: `swe-bench-runner-${$app.stage}-data`,
    },
  });

  const volumeAttachment = new aws.ec2.VolumeAttachment("RunnerDataAttach", {
    deviceName: "/dev/sdf",
    volumeId: dataVolume.id,
    instanceId: instance.id,
  });

  const repoPath = "/opt/swe-bench";
  const miniSweRunsPath = `${repoPath}/mini-swe-runs`;

  return {
    instanceId: instance.id,
    instancePublicIp: instance.publicIp,
    region: aws.getRegionOutput().name,
    dataVolumeId: dataVolume.id,
    repoPath,
    miniSweRunsPath,
    instanceType,
    volumeAttachment: volumeAttachment.id,
  };
}
