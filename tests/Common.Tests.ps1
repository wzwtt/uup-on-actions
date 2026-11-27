<#
Pester v5 unit tests for the pure logic in scripts/Common.psm1. No network
access, no Windows-only prerequisites - the suite runs under PowerShell 5.1
and 7 on any OS.
#>

BeforeAll {
    $modulePath = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) -ChildPath 'scripts/Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'ConvertTo-Bool' {
    It 'accepts the documented truthy and falsy spellings' {
        foreach ($v in @('1', 'true', 'yes', 'y', 'on', 'TRUE', 'Yes')) { ConvertTo-Bool $v | Should -BeTrue }
        foreach ($v in @('0', 'false', 'no', 'n', 'off', 'FALSE', 'No'))  { ConvertTo-Bool $v | Should -BeFalse }
    }
    It 'returns the default for null and empty input' {
        ConvertTo-Bool $null -Default $true | Should -BeTrue
        ConvertTo-Bool '' -Default $false | Should -BeFalse
    }
    It 'rejects values outside the grammar' {
        { ConvertTo-Bool 'maybe' } | Should -Throw
    }
}

Describe 'Get-ShortHash' {
    It 'produces a stable lowercase hex digest of the requested length' {
        Get-ShortHash 'hello' 8 | Should -Be '2cf24dba'
        (Get-ShortHash 'hello' 4).Length | Should -Be 4
    }
}

Describe 'Get-NormalizedArch' {
    It 'normalises aliases' {
        Get-NormalizedArch 'x64' | Should -Be 'amd64'
        Get-NormalizedArch 'AMD64' | Should -Be 'amd64'
        Get-NormalizedArch 'aarch64' | Should -Be 'arm64'
        Get-NormalizedArch 'i386' | Should -Be 'x86'
    }
    It 'rejects unknown architectures' {
        { Get-NormalizedArch 'mips' } | Should -Throw
    }
}

Describe 'ConvertTo-List' {
    It 'splits, trims and drops empty elements' {
        ConvertTo-List ' professional , core ,, ' | Should -Be @('professional', 'core')
        ConvertTo-List '' | Should -Be @()
    }
}

Describe 'Get-UupBuildNumberTuple / Compare-UupBuildNumber' {
    It 'compares numerically, not lexically' {
        Compare-UupBuildNumber '26200.10075' '26200.9999' | Should -Be 1
        Compare-UupBuildNumber '26100.1' '26200.1' | Should -Be -1
        Compare-UupBuildNumber '26200.10075' '26200.10075' | Should -Be 0
    }
    It 'treats unparseable build numbers as zero' {
        Compare-UupBuildNumber '' '1.0' | Should -Be -1
    }
}

Describe 'Test-RingEntryMatchesCategory' {
    It 'matches titles of the same product family and version core' {
        Test-RingEntryMatchesCategory -Title 'Windows 11, version 24H2 (26100.1) amd64' -CategorySlug 'w11-24h2' | Should -BeTrue
        Test-RingEntryMatchesCategory -Title 'Windows Server, version 23H2 (25398.1) amd64' -CategorySlug 'server-23h2' | Should -BeTrue
    }
    It 'matches Server marketing years to their version cores' {
        Test-RingEntryMatchesCategory -Title 'Windows Server 2025 (26100.1) amd64' -CategorySlug 'server-24h2' | Should -BeTrue
        Test-RingEntryMatchesCategory -Title 'Windows Server 2022 (20348.1) amd64' -CategorySlug 'server-22h2' | Should -BeTrue
    }
    It 'rejects other families and version cores' {
        Test-RingEntryMatchesCategory -Title 'Windows 10, version 22H2 (19045.1) amd64' -CategorySlug 'w11-22h2' | Should -BeFalse
        Test-RingEntryMatchesCategory -Title 'Windows 11, version 23H2 (22631.1) amd64' -CategorySlug 'w11-24h2' | Should -BeFalse
        Test-RingEntryMatchesCategory -Title 'Windows Server 2025 (26100.1) amd64' -CategorySlug 'server-23h2' | Should -BeFalse
    }
    It 'never matches insider entries without a version designation' {
        # documented behaviour: beta-channel entries are titled "Windows 11
        # Insider Preview Feature Update (26220.x)" with no version core, so
        # they are only usable with the bare ring form
        Test-RingEntryMatchesCategory -Title 'Windows 11 Insider Preview (29712.1000) arm64' -CategorySlug 'w11-24h2' | Should -BeFalse
        Test-RingEntryMatchesCategory -Title 'Windows 11 Insider Preview Feature Update (26220.1) amd64' -CategorySlug 'w11-25h2-beta' | Should -BeFalse
    }
    It 'matches the Feature-update title form of the Windows 10 branches' {
        Test-RingEntryMatchesCategory -Title 'Feature update to Windows 10, version 1809 (17763.9487) amd64' -CategorySlug 'w10-1809' | Should -BeTrue
        Test-RingEntryMatchesCategory -Title 'Feature update to Windows 10, version 22H2 (19045.7850) amd64' -CategorySlug 'w10-22h2' | Should -BeTrue
    }
}

Describe 'Test-UupFullBuildTitle' {
    It 'accepts the Windows/Server title families' {
        Test-UupFullBuildTitle 'Windows 11, version 25H2 (26200.10075) amd64' | Should -BeTrue
        Test-UupFullBuildTitle 'Windows Server 2025 (26100.33822) amd64' | Should -BeTrue
        Test-UupFullBuildTitle 'Windows 11 Insider Preview Feature Update (26220.9836) arm64' | Should -BeTrue
        Test-UupFullBuildTitle 'Windows 11 (22000.3260) arm64' | Should -BeTrue
    }
    It 'accepts the Feature-update title form used by the Windows 10 branches' {
        Test-UupFullBuildTitle 'Feature update to Windows 10, version 1809 (17763.9487) amd64' | Should -BeTrue
        Test-UupFullBuildTitle 'Feature update to Windows 10, version 22H2 (19045.7850) amd64' | Should -BeTrue
    }
    It 'rejects servicing entries regardless of their prefix' {
        Test-UupFullBuildTitle 'Cumulative Update for Windows 10 Version 1809 (17763.9488) amd64' | Should -BeFalse
        Test-UupFullBuildTitle 'Cumulative Update for Windows Server 2019 (1809) (17763.9487) amd64' | Should -BeFalse
        Test-UupFullBuildTitle 'Servicing Stack Update for Windows 10, version 1809 (17763.1) amd64' | Should -BeFalse
        Test-UupFullBuildTitle '.NET Framework 3.5 and 4.8.1 for Windows 11 (26100.1) amd64' | Should -BeFalse
        Test-UupFullBuildTitle '2026-02 Cumulative Update for Windows 11 (26200.1) amd64' | Should -BeFalse
        Test-UupFullBuildTitle '26100.33732 Security Update (Hotpatch capable) amd64' | Should -BeFalse
    }
}

Describe 'ConvertFrom-OptionsText' {
    It 'parses Key=Value records with comments and blank lines' {
        $map = ConvertFrom-OptionsText "resetbase = true`n`n# a comment`ncleanup=1"
        $map['resetbase'] | Should -Be 'true'
        $map['cleanup'] | Should -Be '1'
        $map.Keys.Count | Should -Be 2
    }
    It 'rejects malformed lines and unknown keys' {
        { ConvertFrom-OptionsText 'resetbase' } | Should -Throw
        { ConvertFrom-OptionsText 'notakey=1' } | Should -Throw
    }
}

Describe 'Merge-UupOptions' {
    It 'applies defaults, then the esd input, then user overrides' {
        $defaults = @{ esd = 'false'; cleanup = 'false'; netfx3 = 'false' }
        $final = Merge-UupOptions -Defaults $defaults -EsdInput 'true' -UserOptions (@{ cleanup = '1' })
        $final['esd'] | Should -Be 'true'
        $final['cleanup'] | Should -Be '1'
        $final['netfx3'] | Should -Be 'false'
    }
    It 'keeps defaults when no override is given' {
        $defaults = @{ esd = 'false'; cleanup = 'false' }
        $final = Merge-UupOptions -Defaults $defaults -EsdInput '' -UserOptions $null
        $final['esd'] | Should -Be 'false'
        $final['cleanup'] | Should -Be 'false'
    }
}

Describe 'Get-UupTag' {
    It 'builds the documented layout with the virtual-edition flag' {
        $final = Merge-UupOptions -Defaults (Get-UupDefaultOptions) -EsdInput 'false' -UserOptions (@{})
        $tag = Get-UupTag -Build '26300.9550' -Arch 'arm64' -Language 'en-us' -Editions @('all') -VirtualEditions @('all') -FinalOptions $final -TagSuffix ''
        $tag | Should -Be '26300.9550-arm64-en-us-all+ve'
    }
    It 'sorts multiple editions alphabetically' {
        $final = Merge-UupOptions -Defaults (Get-UupDefaultOptions) -EsdInput 'false' -UserOptions (@{})
        $tag = Get-UupTag -Build '26200.10075' -Arch 'amd64' -Language 'zh-cn' -Editions @('professional', 'core') -VirtualEditions @() -FinalOptions $final -TagSuffix ''
        $tag | Should -Be '26200.10075-amd64-zh-cn-core-professional'
    }
    It 'appends the option digest when options deviate from the defaults' {
        $final = Merge-UupOptions -Defaults (Get-UupDefaultOptions) -EsdInput 'true' -UserOptions (@{})
        $tag = Get-UupTag -Build '26200.10075' -Arch 'amd64' -Language 'zh-cn' -Editions @('professional') -VirtualEditions @() -FinalOptions $final -TagSuffix ''
        $tag | Should -Match '^26200\.10075-amd64-zh-cn-professional-[0-9a-f]{4}$'
    }
    It 'appends a tag suffix' {
        $final = Merge-UupOptions -Defaults (Get-UupDefaultOptions) -EsdInput 'false' -UserOptions (@{})
        $tag = Get-UupTag -Build '26100.9974' -Arch 'amd64' -Language 'de-de' -Editions @('professional') -VirtualEditions @() -FinalOptions $final -TagSuffix 'hotfix'
        $tag | Should -Be '26100.9974-amd64-de-de-professional-hotfix'
    }
    It 'rejects an empty edition set' {
        $final = Merge-UupOptions -Defaults (Get-UupDefaultOptions) -EsdInput 'false' -UserOptions (@{})
        { Get-UupTag -Build '1.0' -Arch 'amd64' -Language 'zh-cn' -Editions @() -VirtualEditions @() -FinalOptions $final -TagSuffix '' } | Should -Throw
    }
}