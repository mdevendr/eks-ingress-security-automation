#!/bin/bash
aws events delete-rule --name CreateALBRule --force
aws events delete-rule --name DeleteALBRule --force
