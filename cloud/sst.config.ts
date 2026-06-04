/// <reference path="./.sst/platform/config.d.ts" />

import { createRunner } from "./infra/runner";

export default $config({
  app(input) {
    return {
      name: "swe-bench-runner",
      removal: input?.stage === "prod" ? "retain" : "remove",
      home: "aws",
      providers: {
        aws: {
          profile: process.env.AWS_PROFILE,
          region: process.env.AWS_REGION ?? "us-east-1",
        },
      },
    };
  },
  async run() {
    return createRunner();
  },
});
