<#
    .DESCRIPTION
        An example runbook which gets all the ARM resources using the Run As Account (Service Principal)
        Basically the script generates a new NSG contain a aggregate of Onpremise rules and Azure platform rules. 
        To do this uses a “source” NSG. This is managed by a network team and should contain all customer on-premise rules. 
        The second set of rules are generated from the downloaded xml file.
        These two set of rules are combined in a newly created NSG is then attached to the specified network subnet. 
        
        I took this approach as it allows a certain amount of flexibility.
        and additionally it is extremely performant compared to iterating through a list of rules in a existing NSG (powershell loops are slow). It also ensures there is no down time of rules as the very last step is to switch the subnet to the new NSG rule set(it also keeps a history of previous rules that you can roll back to. Much like a promotion mechanism). 
        
    .NOTES
        AUTHOR : Azure Automation Team
        CREATED: Mar 14, 2016
        EDITOR : Peter Lasne, Commercial Software Engineering, Microsoft
        EDITED : Aug 23, 2017
#>

Param
(
    [Parameter (Mandatory= $true)]  [String] $SubscriptionId,
    [Parameter (Mandatory= $true)]  [String] $Location,              ## region containing the source NSG and VNET
    [Parameter (Mandatory= $true)]  [String] $ResourceGroup,         ## name of the Resource Group containing the VNET
    [Parameter (Mandatory= $true)]  [String] $VNET,
    [Parameter (Mandatory= $true)]  [String] $Subnet,
    [Parameter (Mandatory= $false)] [String] $CopyFromResourceGroup, ## name of the Resource Group containing a Resource Group with one or more NSGs
    [Parameter (Mandatory= $false)] [String] $CopyFromNSG,           ## if specified and used with CopyFromResourceGroup, it will restrict which NSG it copies from
    [Parameter (Mandatory= $false)] [String] $AllowRegion,           ## the region to allow inbound traffic from
    [Parameter (Mandatory= $false)] [Switch] $IsInteractive          ## set to $true if running from a command prompt instead of Azure Automation
)

# initialize variables
$rules = @();
$priority = 2000;

# login using the appropriate method
if ($IsInteractive) {

    # login interactively (if not already logged in)
    try {
        Get-AzureRmContext;
    } catch {
        Login-AzureRmAccount;
    }

} else {

    # login using Azure Automation
    try
    {
        $servicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection";
        Write-Output("Logging in to Azure...");
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint;
        Write-Output("Logged in successfully.");
    } catch {
        Write-Output("Error during login; process aborted.");
        Write-Error -Message $_.Exception
        throw $_.Exception
    }

}

# change subscription
Select-AzureRmSubscription -SubscriptionId $subscriptionId;
Write-Output("Changed to subscription $SubscriptionId.");

# copy from other NSGs
if ($CopyFromResourceGroup) {
    try {
        if ($CopyFromNSG) {
            $nsg = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $CopyFromResourceGroup -Name $CopyFromNSG;
            ForEach ($rule in $nsg.SecurityRules) {
                $rules += $rule;
            }
        } else {
            $nsgs = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $CopyFromResourceGroup;
            ForEach ($nsg in $nsgs) {
                ForEach ($rule in $nsg.SecurityRules) {
                    $rules += $rule;
                }
            }
        }
    } catch {
        Write-Output("Error during copy; process aborted.");
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

# apply from Azure region
if ($AllowRegion) {

    # download current list of Azure Public IP addresses
    try {
        $downloadUri = "https://www.microsoft.com/en-in/download/confirmation.aspx?id=41653";
        $downloadPage = Invoke-WebRequest -Uri $downloadUri -UseBasicParsing;
        $xmlFileUri = ($downloadPage.RawContent.Split('"') -like "https://*PublicIps*")[0];
        $response = Invoke-WebRequest -Uri $xmlFileUri -UseBasicParsing; 
    } catch {
        Write-Output("Error during download; process aborted.");
        Write-Error -Message $_.Exception
        throw $_.Exception
    }

    # get list of regions and corresponding public IP address ranges
    [xml]$xmlResponse = [System.Text.Encoding]::UTF8.GetString($response.Content);
    $regions = $xmlResponse.AzurePublicIpAddresses.Region;

    # create the list of rules from the file
    $ipRange = ( $regions | where-object Name -eq $AllowRegion ).IpRange;
    ForEach ($cidr in $ipRange.Subnet) {
        try {

            # create the rule
            $name = "allow-inbound-" + $cidr.Replace("/", "-");
            $rules += New-AzureRmNetworkSecurityRuleConfig `
                -Name $name `
                -Description "Allow inbound from Azure $cidr" `
                -Access Allow `
                -Protocol * `
                -Direction Inbound `
                -Priority $priority `
                -SourceAddressPrefix $cidr `
                -SourcePortRange * `
                -DestinationAddressPrefix VirtualNetwork `
                -DestinationPortRange *;

            # increment the priority
            $priority++;

            # write out the CIDR addresses as they are identified
            Write-Output("Added CIDR $cidr as rule $name.");

        } catch {
            Write-Output("Error during rule creation; process aborted.");
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }

}

# create a new NSG
try {
    $name = "allow-inbound-" + (Get-Date -f yyyyMMddHHmm);
    $nsg = New-AzureRmNetworkSecurityGroup `
        -Name $name `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -SecurityRules $rules `
        -ErrorAction Stop;
    Write-Output("Created NSG: $name.");
} catch {
    Write-Output("Error during create NSG; process aborted.");
    Write-Error -Message $_.Exception
    throw $_.Exception
}

# get the vnet/subnet references
$vnet_actual = Get-AzureRmVirtualNetwork -ResourceGroupName $ResourceGroup -Name $VNET;
$subnet_actual = $vnet_actual.Subnets | Where-Object Name -eq $Subnet
Write-Output("Applying to Resource Group: $ResourceGroup, VNET: $VNET, Subnet: $Subnet...");

# assign the NSG to the subnet
try {
    Set-AzureRmVirtualNetworkSubnetConfig `
        -VirtualNetwork $vnet_actual `
        -Name $Subnet `
        -AddressPrefix $subnet_actual.AddressPrefix `
        -NetworkSecurityGroup $nsg | Set-AzureRmVirtualNetwork;
} catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
    Write-Output("Error during assign NSG to subnet; process aborted.");
}