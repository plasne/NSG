# Azure Create Derivative NSG

This PowerShell cmdlet lets you copy rules from one or more NSGs into a new NSG and/or apply all rules from a specific region in the Azure IP Address Ranges (https://www.microsoft.com/en-us/download/details.aspx?id=41653). Currently the IP Addresses from the Azure list are only applied as Inbound Rules, but it would be a simple change if you wanted something different.

I started this code from here: https://gist.github.com/ivanthelad/11af35055eafd4922ec4f5e886ee8a71, so special thanks to the Azure Automation Team for making this easy.

# Limits

NSGs can have to 200 Rules by default, but for some regions, this will not be enough. Thankfully, you can request a limit increase up to 500 via the Azure portal.

# Running Interactively

While it is likely that you would want to run this as an Azure Automation Job, it is possible to run this interactively:

```PowerShell
.\nsg.ps1 `
    -SubscriptionId 11111111-1111-1111-11111111 `
    -Location eastus2 `
    -ResourceGroup myrg `
    -VNET myvnet `
    -Subnet mysubnet `
    -CopyFromResourceGroup srcrg `
    -CopyFromNSG srcnsg `
    -AllowRegion useast2 `
    -IsInteractive
```

The following parameters are optional:

* CopyFromResourceGroup
* CopyFromNSG
* AllowRegion

If you specify CopyFromResourceGroup only it will copy all the Rules from all NSGs in the specified Resource Group. You need to make sure that all the Rules have a different priority. Also, Rules pulled using AllowRegion start at 2000 and go up one at a time (2000, 2001, 2002, ...), so you should avoid that range as well.

If you specify CopyFromNSG and CopyFromResourceGroup (it won't do anything on its own), it will copy all the Rules from the specified NSG.

If you specify AllowRegion then it will download the list of CIDR ranges and then apply those as Inbound Rules.

# Region Designations

For some reason there is not consistency in how regions are named in the IP range file versus how ARM expects them to be named. In the above example, you can see that AllowRegion uses "useast2" (per the XML file), while Location uses "eastus2" (the name of the region in ARM).

# Running in Azure Automation

To run in Azure Automation, you must add AzureRM.Network module. This has dependencies though that will probably require you to update the included modules.

* Under the Azure Automation Account, go to Modules, click on "Update Azure Modules".
* When that is done, under Modules Gallery, search for "AzureRM.Network" and Import it.

# Using with HDInsight

If you are going to use this with HDInsight you must allow a specific set of IP addresses for inbound (outbound filtering isn't supported with HDI). Those IP addresses vary per region, but you can find what you need here:

https://docs.microsoft.com/en-us/azure/hdinsight/hdinsight-extend-hadoop-virtual-network#hdinsight-ip

You can implement this simply by creating a NSG with the Rules and then using CopyFromResourceGroup.