# BV-BRC Application Service

## Overview

The BV-BRC application service provides the client and server-side support for the execution of BV-BRC computational services.

It has two main components: a backend scheduler which manages a queue of application execution requests (or tasks), and a persistent JSONRPC-based service that provides user-level services.

The scheduler maintains the queue of tasks to be executed in a MySQL database. For each task, we maintain the following information:

- User who owns the task
- Application name
- Parameters object defining the input and output for the task
- Job execution metadata

The scheduler uses a system scheduler - in the production system, a Slurm scheduler attached to a HPC compute cluster - to execute the user tasks. It periodically checks the task queue for available work while maintaining basic fairness constraints, and feeds tasks to the system scheduler as appropriate. The system scheduler will execute users tasks under the control of a [application shepherd](https://github.com/BV-BRC/p3_app_shepherd) which collects job statistics and relays job standard output and error streams to the application service.

The application service provides several services to the end-user:

- API to browse the user's jobs
- API for administrators to manage job status (rerunning failed jobs, changing memory and time requirements, etc.)
- Providing access to the job standard output and error streams

## About this module

This module is a component of the BV-BRC build system. It is designed to fit into the
`dev_container` infrastructure which manages development and production deployment of
the components of the BV-BRC. More documentation is available [here](https://github.com/BV-BRC/dev_container/tree/master/README.md).
