## $Id$
##
## BEGIN LICENSE BLOCK
##
## Copyright (C) 2002  Damon Courtney
## 
## This program is free software; you can redistribute it and/or
## modify it under the terms of the GNU General Public License
## version 2 as published by the Free Software Foundation.
## 
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License version 2 for more details.
## 
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the
##     Free Software Foundation, Inc.
##     51 Franklin Street, Fifth Floor
##     Boston, MA  02110-1301, USA.
##
## END LICENSE BLOCK

proc ::bgerror {err} {
    if {$::conf(building)} {
        BuildLog $::errorInfo -tags error
        BuildDone 1
    } else {
        ::InstallJammer::Message -icon error -message $::errorInfo
    }
}

proc BuildLog { text args } {
    global conf
    global widg

    array set _args {
        -tags       {}
        -logtofile  1
        -nonewline  0
    }
    array set _args $args

    set error [expr {[lsearch -exact $_args(-tags) error] > -1}]
    incr conf(buildErrors) $error
    incr conf(totalBuildErrors) $error

    Status [lindex [split $text \n] 0]

    set date "[clock format [clock seconds] -format "%D %H:%M:%S"]"

    set string "$date - $text"
    if {$conf(logBuild) && $_args(-logtofile)} {
	if {![info exists conf(logfp)]} {
	    set conf(logfp) [open [::InstallJammer::GetBuildLogFile] a+]
            fconfigure $conf(logfp) -translation lf
	}
	puts  $conf(logfp) $string
	flush $conf(logfp)
    }

    if {[info exists widg(BuildLog)]} { 
        if {!$_args(-nonewline)} { append text \n }

        set auto [expr {[lindex [$widg(BuildLog) yview] 1] == 1}]

	$widg(BuildLog):cmd insert end "$date - " "" $text $_args(-tags)
        if {$auto} { $widg(BuildLog) see end }
        update idletasks
    } else {
	if {$error} {
            puts  stderr $string
            flush stderr
        } elseif {!$conf(silent) && ($conf(verbose) || $_args(-logtofile))} {
            puts  stdout $string
            flush stdout
        }
    }
} 

proc ::InstallJammer::ClearBuildLog {} {
    global widg

    if {[info exists widg(BuildLog)] && [winfo exists $widg(BuildLog)]} {
        $widg(BuildLog) clear
    }
}

proc ::InstallJammer::BuildOutput { line {errorInfo ""} } {
    global conf

    ::InstallJammer::CheckForBuildStop

    if {$line eq ""} { return }

    catch { lindex $line 0 } cmd

    if {$errorInfo ne ""} { set line $::errorInfo }

    switch -- $cmd {
        ":FILE" {
            ::InstallJammer::LogPackedFile [lindex $line 1]
            FileProgress 0
        }

        ":FILEPERCENT" {
            FileProgress [lindex $line 1]
        }

        ":PERCENT" {
            PlatformProgress [lindex $line 1]
        }

        ":ERROR" {
            BuildLog [lindex $line 1] -tags error
        }

        ":ECHO" {
            BuildLog [lindex $line 1]
        }

        ":DONE" {
            if {[threaded]} { ::InstallJammer::FinishBuild }
        }

        default {
            BuildLog $line -tags error
        }
    }
}

proc ::InstallJammer::LogPackedFile { file } {
    BuildLog "Packing $file..." -logtofile 0
}

proc ::InstallJammer::ReadBuild { fp } {
    set close 0
    if {[gets $fp line] == -1} { set close 1 }

    ::InstallJammer::BuildOutput $line

    if {$close} {
        if {[catch { close $fp } err]} {
            BuildLog $err -tags error
        }

        ::InstallJammer::FinishBuild
    }
}

proc ::InstallJammer::FinishBuild { {errors 0} } {
    global conf
    global widg

    variable ::InstallJammer::solid

    ::InstallJammer::CheckForBuildStop 0

    set platform $conf(buildPlatform)
    set pretty   [PlatformText $platform]

    if {[::InstallJammer::IsRealPlatform $platform]} {
        set execdir [file dirname $conf(executable)]
        file delete -force [file join $execdir runtime]
    }

    if {$conf(buildStopped)} {
        BuildDone
        return
    }

    if {$errors} {
        BuildLog "$pretty build completed with errors" -tags error
        Status "$pretty build errored." 3000
        ::InstallJammer::CallHook OnBuildFailure $platform
        BuildNext
        return
    }

    if {[info exists solid]} {
        foreach methodName [lsort [array names solid]] {
            set method [lindex $methodName 0]
            BuildLog "Building $method solid archive..."

            set archive [::InstallJammer::BuildDir solid.$method]

            set files {}
            foreach {fileid file} $solid($methodName) {
                lappend files [list $file -name $fileid]
            }
            set fp [miniarc::open crap $archive w -method none -flatheaders 1]
            miniarc::addfilelist $fp $files \
                -progress ::InstallJammer::LogPackedFile
            miniarc::close $fp

            BuildLog "Storing $method solid archive..."
            set fp [miniarc::open crap $conf(tmpExecutable) a -method $method]
            miniarc::addfile $fp $archive -name solid.$method
            miniarc::close $fp

            file delete -force $archive
        }
    }

    if {[info exists conf(tmpExecutable)] && [file exists $conf(tmpExecutable)]
        && [catch {
            file rename -force $conf(tmpExecutable) $conf(executable)
        }]} {
        set errors 1
        BuildLog "Could not rename temporary build file to final\
                    installer.  Installer may be running." -tags error
    }

    if {$errors} {
        BuildLog "$pretty build completed with errors" -tags error
        Status "$pretty build errored." 3000
        ::InstallJammer::CallHook OnBuildFailure $platform
    } else {
        if {$platform in "MacOS-X MacOS-X-ppc"
            && [$platform get BuildType] eq ".app bundle"} {
            BuildAppBundle $platform
        }

        set secs  [expr [clock seconds] - $conf(buildForPlatformStart)]
        set fmt "%Mm%Ss"
        set time [clock format $secs -format $fmt -gmt 1]
        set size [file size $conf(executable)]
        BuildLog "$pretty build completed in $time."
        BuildLog "Installer size is [::InstallJammer::FormatDiskSpace $size]."

        if {[info exists widg(BuildLog)]} {
            set auto [expr {[lindex [$widg(BuildLog) yview] 1] == 1}]
            set date "[clock format [clock seconds] -format "%D %H:%M:%S"]"
            $widg(BuildLog):cmd insert end "$date - Installer located at "
            $widg(BuildLog):cmd insert end [file tail $conf(executable)] link
            $widg(BuildLog):cmd insert end \n
            if {$auto} { $widg(BuildLog) see end }
        }

        ::InstallJammer::CallHook OnBuildSuccess $platform $conf(executable)
        Status "$pretty build complete." 3000
    }

    BuildNext
}

proc ::InstallJammer::TryToDeleteFile { file {tries 0} {timeout 10} } {
    if {[file exists $file]} {
        if {[catch { file delete -force $file }]} {
            if {[incr tries] < $timeout} { after 500 [info level 0] }
        }
    }
}

proc BuildNext {} {
    global conf

    ::InstallJammer::CheckForBuildStop

    PlatformProgress 100

    incr conf(buildIdx)
    set next [lindex $conf(buildList) $conf(buildIdx)]

    if {$next eq ""} {
        BuildDone
    } else {
        set conf(buildErrors)   0
        set conf(buildPlatform) $next
        BuildForPlatform $next
    }
}

proc BuildDone { {errors 0} } {
    global conf
    global info
    global widg

    if {[info exists widg(StopBuildButton)]} {
        $widg(StopBuildButton) configure -state disabled
    }

    variable ::InstallJammer::saveConf
    if {[info exists saveConf]} {
        array set conf $saveConf
        unset saveConf
    }

    variable ::InstallJammer::saveInfo
    if {[info exists saveInfo]} {
        array set info $saveInfo
        unset saveInfo
    }

    ::InstallJammer::StatusPrefix

    set conf(building)  0
    set conf(buildList) {}

    set secs [expr {[clock seconds] - $conf(buildStart)}]
    set time [clock format $secs -format "%Mm%Ss" -gmt 1]

    if {$errors} {
        BuildLog "Fatal error in build." -tags error
        BuildLog "Build stopped." -tags error
        Status "Build stopped." 3000
    } elseif {!$conf(buildStopped)} {
        BuildLog "Build completed in $time."
        Status "Build complete." 3000
    } else {
        BuildLog "Build stopped by user." -tags error
        Status "Build stopped." 3000
        ::InstallJammer::TryToDeleteFile $conf(tmpExecutable)
    }

    file delete -force $conf(stop) $conf(pause)

    if {[file exists [file join $conf(buildDir) bin]]} {
        file delete -force [file join $conf(buildDir) bin]
    }

    if {[info exists conf(logfp)]} {
	catch { close $conf(logfp) }
	unset -nocomplain conf(logfp)
    }

    unset -nocomplain info(Platform)
    unset -nocomplain conf(buildStart)
    unset -nocomplain conf(buildPlatform)

    FileProgress     0
    BuildProgress    0
    PlatformProgress 0

    ::InstallJammer::SetLastBuilt

    ::InstallJammer::SetMainWindowTitle

    ::InstallJammer::FlashMainWindow

    set ::conf(buildDone) 1
}

proc BuildUninstallData { infoArrayName } {
    global conf
    global info
    global widg

    upvar 1 $infoArrayName buildInfo

    set files [ThemeFiles Uninstall]
    set files [lremove $files init.tcl main.tcl user.tcl windows.tcl]
    lappend files windows.tcl user.tcl

    set data [read_file [file join $conf(lib) header.tcl]]

    #append data [ReadableArrayGet buildInfo info]\n

    append data [::InstallJammer::GetCommandLineOptionData -build 1 \
                -setup Uninstall -includedebug $info(IncludeDebugging)]\n

    append data "\nset PaneList [list [GetPaneList Uninstall 1]]\n"

    append data [::InstallJammer::SaveProperties -build 1 -setup Uninstall \
        -activeonly 1 -includecomments $info(IncludeDebugging) \
        -array ::InstallJammer::Properties]

    append data [::InstallJammer::BuildComponentData Uninstall]\n

    append data [::InstallJammer::GetWindowProcData \
        -build 1 -setups Uninstall -activeonly 1]

    set themedir [::InstallJammer::ThemeDir]

    append data [ShrinkFile [file join $themedir Uninstall init.tcl]]\n

    append data [ShrinkFile [file join $conf(lib) uninstall.tcl]]\n

    foreach file $files {
	set ext [string tolower [file extension $file]]
	if {![string equal $ext ".tcl"]} { continue }
	append data [ShrinkFile [file join $themedir Uninstall $file]]\n
    }

    foreach file [lremove [ThemeFiles Common] setup.tcl] {
        append data [ShrinkFile [::InstallJammer::ThemeFile Common $file]]\n
    }

    ## Store the component objects in the uninstall.
    append data [::InstallJammer::SaveInstallComponents \
                    -build 1 -setup Uninstall -activeonly 1]\n

    append data [ShrinkFile [file join $themedir Uninstall main.tcl]]\n

    return $data
}

proc BuildConditionsData { setup } {
    global conf

    set data ""

    set conditions [list]
    foreach id [GetComponentList $setup 1] {
        foreach cid [$id conditions] {
            lappend conditions [$cid component]
        }
    }

    foreach condition [lsort -unique $conditions] {
        append data [ProcDefinition ::InstallJammer::conditions::$condition 0]\n
    }

    return $data
}

proc ::InstallJammer::GetComponentProcDefinition { component } {
    variable ::InstallJammer::actions
    variable ::InstallJammer::conditions

    if {[info exists actions($component)]} {
        return [ProcDefinition ::InstallJammer::actions::$component 0]
    } elseif {[info exists conditions($component)]} {
        return [ProcDefinition ::InstallJammer::conditions::$component 0]
    }
}

proc ::InstallJammer::BuildComponentData { setup {activeOnly 1} } {
    set list [list]
    foreach id [GetComponentList $setup $activeOnly] {
        if {[$id is action]} {
            lappend list [$id component]
            eval lappend list [[$id object] includes]
        }

        foreach cid [$id conditions] {
            lappend list [$cid component]
            eval lappend list [[$cid object] includes]
        }
    }

    set    data "namespace eval ::InstallJammer::actions {}\n"
    append data "namespace eval ::InstallJammer::conditions {}\n"

    foreach id [lsort -unique $list] {
        append data [GetComponentProcDefinition $id]\n
    }

    return $data
}

proc BuildActionsData { setup {activeOnly 1} } {
    set data "namespace eval ::InstallJammer::actions {}\n"
    foreach action [::InstallJammer::GetActionList $setup $activeOnly] {
        append data [ProcDefinition ::InstallJammer::actions::$action 0]\n
    }
    return $data
}

proc BuildGuiData {} {
    set data "proc ::InitGui {} \{"

    append data {
        global conf
        global info

        if {[info exists ::conf(initGui)]} { return }
        set conf(initGui) 1

	set conf(x11)  0
	set conf(aqua) 0

        if {[catch { package require Tk } error]} {
            if {!$::info(FallBackToConsole)} {
                puts "This program must be run in a graphical environment,"
                puts "or you must specify a silent or console install."
                ::InstallJammer::ShowUsageAndExit
            }

            set info(GuiMode)       0
            set info(SilentMode)    0
            set info(DefaultMode)   0
            set info(ConsoleMode)   1
            set info($::conf(mode)) "Console"

            if {![catch { exec stty size } result]
                && [scan $result "%d %d" height width] == 2} {
                set conf(ConsoleWidth)  $width
                set conf(ConsoleHeight) $height
            }

            return
        }

        set info(GuiMode) 1

	set conf(wm)   [tk windowingsystem]
	set conf(x11)  [string equal $::conf(wm) "x11"]
	set conf(aqua) [string equal $::conf(wm) "aqua"]

        if {$conf(aqua)} {
            menu .m
            menu .m.apple
            . configure -menu .m
            .m add cascade -label "Apple" -menu .m.apple
            .m.apple insert end command -label "About this installer" \
                -command ::InstallJammer::DisplayVersionInfo
        }

        wm withdraw .
        if {$conf(windows)} {
            wm iconbitmap . -default [file join $conf(vfs) installkit.ico]
        }
        
        namespace eval :: { namespace import ::ttk::style }

        if {$conf(x11)} { ttk::setTheme jammer }

        bind TButton <Return> "%W invoke; break"
    }

    append data [GetImageData {Install Uninstall} 1]\n

    ## Add the install theme's setup code.
    append data [ShrinkFile [::InstallJammer::ThemeDir Common/setup.tcl]]\n

    append data "ThemeSetup\n"

    append data [BuildBWidgetData]\n

    append data "ThemeInit\n"

    append data "::InstallJammer::HideMainWindow\n"

    append data "BWidget::use ttk 1 -force 1\n"

    append data "\}\n"

    return $data
}

proc BuildBWidgetData {} {
    global conf

    ## FIXME: Need to figure out how to append only certain BWidgets.
    #set bwidgets [list Wizard ListBox Tree Label]
    #lappend bwidgets -exclude [list DynamicHelp DragSite DropSite]

    set initlibs [list widget utils]

    set libs [list init label tree optiontree listbox \
        separator ttkbutton button buttonbox dialog scrollw \
        icons choosedir choosefile messagedlg text wizard]

    set data ""

    foreach lib $initlibs {
        append data [ShrinkFile [file join $conf(lib) BWidget $lib.tcl]]\n
    }

    append data [ShrinkFile [file join $conf(lib) bwidget.tcl]]\n
    append data "BWidgetInit\n"

    foreach lib $libs {
        append data [ShrinkFile [file join $conf(lib) BWidget $lib.tcl]]\n
    }

    append data "BWidget::LoadBWidgetIconLibrary\n"

    return $data
}

proc ::InstallJammer::BuildAPIData { varName } {
    upvar 1 $varName fullcode

    set data ""
    set code $fullcode

    ## We want to recursively walk through the procs in
    ## the ::InstallAPI namespace and check our code to
    ## see if they're used.
    set pattern {::InstallAPI::[a-zA-Z0-9_-]+}
    while {1} {
        set found 0

        foreach proc [lsort -unique [regexp -all -inline $pattern $code]] {
            if {![info exists done($proc)]} {
                set found 1
                set done($proc) 1
                append data [ProcDefinition $proc 0]\n
            }
        }

        if {!$found} { break }

        set code $data
    }

    append fullcode $data
    return $data
}

proc ::InstallJammer::IncludeFfidl { code } {
    global info
    if {[info exists info(IncludeFfidlPackage)]
        && $info(IncludeFfidlPackage)} { return 1 }
    set pattern {ffidl::[a-zA-Z0-9_-]+}
    return [regexp $pattern $code]
}

proc ::InstallJammer::IncludeTWAPI { code } {
    global info
    if {[info exists info(IncludeTwapiPackage)]
        && $info(IncludeTwapiPackage)} { return 1 }
    set pattern {twapi::[a-zA-Z0-9_-]+}
    return [regexp $pattern $code]
}

proc ::InstallJammer::BuildPackageData { platform } {
    global conf
    global info

    set bin 0
    set cmd [list]

    set done(InstallJammer) 1

    foreach pkg [::InstallJammer::GetRequiredPackages 1] {
        if {[info exists done($pkg)]} { continue }
        set done($pkg) 1

        ## Look for the package as a platform-specific package first.
        set path [file join $conf(pwd) Binaries $platform lib $pkg]
        if {![file exists $path]} {
            set path [file join $conf(lib) packages $pkg]
        }

        ## Look for the package in lib/packages.
        if {![file exists $path]} { continue }

        ## If the required package is a directory, just add
        ## it to our list of packages.  Otherwise, it's a
        ## script, and we want to copy it to a bin directory
        ## that we'll include as a package.
        if {[file isdirectory $path]} {
            set desc [file join $path ijdesc.pkg]
            if {[file exists $desc]} {
                set d [::InstallJammer::ReadPackageDescription $desc]
                set pkg [dict get $d package]
                if {[info exist done($package)]} { continue }
                set done($package) 1
            }
            lappend cmd -package $path
        } else {
            set dir [file join $conf(buildDir) bin]

            file mkdir $dir
            file copy -force $path $dir

            if {!$bin} {
                set bin 1
                lappend cmd -package $dir
            }
        }
    }

    if {![llength $conf(packages)]} { ::InstallJammer::GetExternalPackages }
    dict for {key d} $conf(packages) {
        lassign [split $key |] package dir
        if {![info exists info(Include${package}Package)]
            || !$info(Include${package}Package)} { continue }
        if {[dict get $d platform] ne ""
            && [dict get $d platform] ne $platform} { continue }
        if {[info exists done($package)]} { continue }
        set done($package) 1
        lappend cmd -package $dir
    }

    foreach dir [list [file join $conf(lib) packages] [InstallDir packages]] {
        ## Find any packages in the packages/<platform> directory
        ## that we need to include in our installer.
        set dir [file join $dir $platform]

        set platforms [AllPlatforms]
        foreach pkg [glob -nocomplain -type d -dir $dir -tails *] {
            if {[info exists done($pkg)]} { continue }
            set done($pkg) 1

            if {[file exists [file join $dir $pkg ijpkg.desc]]} { continue }

            lappend cmd -package [file join $dir $pkg]
        }

        ## Now check for non-platform-specific packages in the
        ## lib/packages directory to include.
        set dir [file dirname $dir]
        foreach pkg [glob -nocomplain -type d -dir $dir -tails *] {
            if {$pkg eq "Default.app"} { continue }
            if {[info exists done($pkg)]} { continue }
            set done($pkg) 1

            if {[file exists [file join $dir $pkg ijpkg.desc]]} { continue }
            if {[lsearch -exact $platforms $pkg] > -1} { continue }

            lappend cmd -package [file join $dir $pkg]
        }
    }

    return $cmd
}

proc ::InstallJammer::BuildFileManifest {filelist} {
    global conf

    variable ::InstallJammer::solid

    BuildLog "Building file manifest..."

    set fp [open $conf(packManifest) w]
    fconfigure $fp -translation lf

    if {$conf(buildArchives)} {
        set ffp [open $conf(fileManifest) w]
        fconfigure $ffp -translation lf
    }

    set i 0
    set nFiles 0
    foreach list $filelist {
        incr nFiles
        lassign $list srcid file group size mtime method

        if {[string match "*(solid)*" $method]} {
            lappend solid($method) $srcid $file
        } elseif {$conf(buildArchives)} {
            puts $ffp $list
            if {![info exists archives($group)]} {
                set archives($group) setup[incr i].ijc
                lappend conf(archiveFiles) $archives($group)
            }
        } else {
            puts $fp [list $file $srcid $method]
        }
    }

    foreach file [::InstallJammer::GetComponentExtraFiles Install] {
        incr nFiles
        puts $fp [list $file support/[file tail $file]]
    }

    close $fp
    if {[info exists ffp]} { close $ffp }

    if {!$nFiles} {
        file delete -force $conf(packManifest) $conf(fileManifest)
    }

    return [array get archives]
}

proc VirtualTextData {} {
    global info

    set data [list]
    foreach var [lsort [array names info]] {
        if {![::InstallJammer::IsReservedVirtualText $var]} {
            lappend data $var $info($var)
        }
    }

    return $data
}

proc Progress { {amt ""} } {
    global conf
    global widg

    if {$conf(cmdline)} { return }

    if {![lempty $amt]} {
	set ::conf(progress) $amt
    } else {
	incr ::conf(progress)
    }
    set value [$widg(Progress) cget -value]
    if {[info exists widg(Progress)]} {
	$widg(Progress) configure -value $::conf(progress)
    }

    if {!$amt} {
        ## If amt is 0, remove the progressbar.
        grid remove $widg(Progress)
        $widg(Status) configure -showresizesep 0
    } elseif {$amt && !$value} {
        ## If amt is greater than 0 and our previous value
        ## was 0, we need to grid the progressbar into place.
        grid $widg(Progress)
        $widg(Status) configure -showresizesep 1
        update idletasks
    }

    #update idletasks
}

proc PlatformProgress { amt } {
    global conf
    global widg

    if {$conf(cmdline)} { return }

    if {$conf(building)} {
        set len [llength $conf(buildList)]
        set x   [expr {round($amt / $len)}]
        BuildProgress $x
    }

    set conf(buildPlatformProgress) $amt

    if {[info exists widg(ProgressBuildPlatform)]
	&& [winfo viewable $widg(ProgressBuildPlatform)]} {
	$widg(ProgressBuildPlatform) configure -value $amt
	#update idletasks
    }
}

proc BuildAppBundle {platform} {
    global conf

    variable ::InstallJammer::buildInfo

    BuildLog "Building .app bundle..."

    set defdir [InstallDir packages/Default.app]
    if {![file exists $defdir]} {
        set defdir [file join $conf(lib) packages Default.app]
    }

    set execdir [file dirname $conf(executable)]
    if {$conf(buildArchives)} {
        set appdir [file dirname $execdir]
        set appdir [file join $appdir [file tail $conf(executable)].app]
    } else {
        set appdir [::InstallJammer::BuildDir $conf(executable).app]
    }
    if {[file exists $appdir] && !$conf(rebuildOnly)} {
        file delete -force $appdir
    }
    if {![file exists $appdir]} {
        file copy $defdir $appdir
    }
    file mkdir [file join $appdir Contents MacOS]
    file copy -force $conf(executable) \
        [file join $appdir Contents MacOS installer]

    if {!$conf(rebuildOnly) && $conf(buildArchives)} {
        foreach file $conf(archiveFiles) {
            file copy -force [file join $execdir $file] \
                [file join $appdir Contents MacOS]
        }
    }

    set map [list @VersionDescription@ [sub [$platform get VersionDescription]]]
    foreach {var val} [array get buildInfo] {
        lappend map @$var@ [sub $val]
    }

    set pinfo [read_file [file join $defdir Contents Info.plist]]
    set fp [open [file join $appdir Contents Info.plist] w]
    puts -nonewline $fp [string map $map $pinfo]
    close $fp

    file mtime $appdir [clock seconds]
}

proc BuildProgress { amt } {
    global conf
    global widg

    if {$conf(cmdline)} { return }

    if {$conf(building)} {
        if {!$amt} { return }
        set len [llength $conf(buildList)]
        set conf(buildProgress) [expr {$amt + ($conf(buildIdx) * (100 / $len))}]
    } else {
        set conf(buildProgress) 0
    }

    if {[info exists widg(ProgressBuild)]
	&& [winfo viewable $widg(ProgressBuild)]} {
	$widg(ProgressBuild) configure -value $::conf(buildProgress)
	#update idletasks
    }
    ::InstallJammer::SetMainWindowTitle
    Progress $conf(buildProgress)
}

proc FileProgress { {amt ""} } {
    global conf
    global widg

    if {$conf(cmdline)} { return }

    if {![lempty $amt]} {
	set ::conf(fileProgress) $amt
    } else {
	incr ::conf(fileProgress)
    }
    if {[info exists widg(ProgressBuildFile)]
	&& [winfo viewable $widg(ProgressBuildFile)]} {
	$widg(ProgressBuildFile) configure -value $::conf(fileProgress)
	#update idletasks
    }
}

## FIXME:  Fix GetInstallComponentFiles
## Needs to be updated to actually get the full list of files needed
## when building.  This is usually just a list of icons that need to
## get included in the install.
proc ::InstallJammer::GetComponentExtraFiles { setup } {
    global conf

    set files [list]
    foreach id [GetComponentList $setup 1] {
        switch -- [$id component] {
            "InstallWishBinary" -
            "InstallWrappedScript" -
            "InstallWrappedApplication" {
                set icon [$id get WindowsIcon]
                if {![string length $icon]} { continue }

		if {[string equal [file pathtype $icon] "relative"]} {
		    set icon [file join $conf(pwd) Images "Windows Icons" $icon]
		}
		lappend files $icon
	    }
	}
    }

    return [lsort -unique $files]
}

proc ::InstallJammer::QuickBuild { {platforms {}} } {
    global conf

    variable saveConf

    set saveConf [list rebuildOnly $conf(rebuildOnly)]

    set conf(rebuildOnly) 1

    Build $platforms
}

proc ::InstallJammer::PauseBuild {} {
    global conf
    if {$conf(building)} {
        close [open $conf(pause) w]
    }
}

proc ::InstallJammer::StopBuild {} {
    global conf
    if {$conf(building)} {
        ::InstallJammer::PauseBuild
        close [open $conf(stop)  w]
    }
}

proc ::InstallJammer::CheckForBuildStop { {stop 1} } {
    global conf

    if {$conf(cmdline)} { return }

    if {$conf(buildStopped)} {
        if {$stop} { return -code return }
        return
    }

    while {[file exists $conf(pause)]} {
        if {[file exists $conf(stop)]} {
            set conf(buildStopped) 1
            if {!$stop} { return }

            ::InstallJammer::FinishBuild
            return -code return
        }
        after 500
    }
}

proc Build { {platforms {}} } {
    global conf
    global info
    global widg

    if {$conf(demo)} {
	set    msg "Cannot build installs in demo mode."
	append msg "Please see About Demo Mode for more information."

	::InstallJammer::Message -title "InstallJammer Demo Mode" -message $msg
    	return
    }

    if {!$conf(projectLoaded)} {
	::InstallJammer::Message -message "No project loaded!"
	return
    }

    if {$conf(building)} {
	::InstallJammer::Error -message "A build is already in progress."
	return
    }

    set conf(buildErrors) 0
    set conf(totalBuildErrors) 0

    if {$conf(buildForRelease)} {
        variable ::InstallJammer::saveConf
        variable ::InstallJammer::saveInfo

        set saveConf [list \
                rebuildOnly $conf(rebuildOnly) \
                buildMainTclOnly $conf(buildMainTclOnly)]

        set saveInfo [list \
                IncludeDebugging $info(IncludeDebugging)]

        set conf(rebuildOnly)      0
        set conf(buildMainTclOnly) 0

        set info(IncludeDebugging) 0

        BuildLog "Configuring build for final release..."
    }

    if {!$conf(rebuildOnly) && [info exists widg(Product)]} {
        $widg(Product) raise diskBuilder
        update
    }

    if {$conf(fullBuildRequired) && $conf(rebuildOnly)} {
        set msg "The installer format has changed and a full rebuild is\
                required.  Do you want to continue with the full build?"

	set ans [::InstallJammer::MessageBox \
	    -title "Full Build Required" -type yesno -message $msg]

        if {$ans eq "no"} { return }

        set conf(rebuildOnly)       0
        set conf(fullBuildRequired) 0
    }

    set conf(stop)  [::InstallJammer::BuildDir .stop]
    set conf(pause) [::InstallJammer::BuildDir .pause]
    file delete -force $conf(stop) $conf(pause)

    ::InstallJammer::SaveActiveComponent

    set conf(buildIdx)     -1
    set conf(buildDir)     [::InstallJammer::BuildDir]
    set conf(buildDone)    0
    set conf(buildList)    [list]
    set conf(buildStart)   [clock seconds]
    set conf(buildStopped) 0
    set conf(refreshFiles) $info(AutoRefreshFiles)

    set all  [AllPlatforms]
    set real 0
    if {[lempty $platforms]} {
	foreach platform [ActivePlatforms] {
	    if {!$conf(build,$platform)}  { continue }
            incr real
	    lappend conf(buildList) $platform
	}

        if {!$conf(rebuildOnly)} {
            foreach archive $conf(Archives) {
                if {$conf(build,$archive) && [$archive get Active]} {
                    lappend conf(buildList) $archive
                }
            }
        }
    } else {
        foreach platform $platforms {
            if {[lsearch -exact $all $platform] > -1} {
                incr real
                lappend conf(buildList) $platform
            } else {
                if {!$conf(rebuildOnly)
                    && [string equal -nocase $platform "tar"]} {
                    lappend conf(buildList) TarArchive
                }
            }
        }
    }

    if {![llength $conf(buildList)]} {
        BuildLog "Nothing to build."
        return
    }

    if {!$conf(cmdline)} {
        set conf(buildProgress) 0
        grid $widg(Progress)
        $widg(Status) configure -showresizesep 1
        update idletasks
        $widg(BuildLog) see end
    }

    file mkdir [::InstallJammer::BuildDir] [::InstallJammer::OutputDir]

    BuildLog "Building message catalogs..."

    if {$real} {
        set fp [open [::InstallJammer::BuildDir messages] w]
        fconfigure $fp -translation lf -encoding utf-8
        puts $fp [::InstallJammer::GetTextData -setups Install \
            -activeonly 1 -build 1]
        close $fp
    }

    if {$conf(filesModified)} {
        foreach platform [AllPlatforms] {
            set file [::InstallJammer::BuildDir ${platform}-files.tcl]
            if {[file exists $file]} {
                file delete -force $file
            }
        }
        ::InstallJammer::FilesModified 0
    }

    if {[info exists widg(StopBuildButton)]} {
        $widg(StopBuildButton) configure -state normal
    }

    BuildNext

    if {!$conf(buildDone) && $conf(cmdline)} {
        vwait ::conf(buildDone)
    }
}

proc BuildForPlatform { platform } {
    global conf
    global info
    global widg

    variable ::InstallJammer::buildInfo
    unset -nocomplain buildInfo

    variable ::InstallJammer::solid
    unset -nocomplain solid

    ::InstallJammer::CheckForBuildStop

    set conf(building) 1
    set conf(buildPlatform) $platform
    set conf(buildPlatformProgress) 0
    set conf(buildForPlatformStart) [clock seconds]

    set info(Ext)      [expr {$platform eq "Windows" ? ".exe" : ""}]
    set info(Platform) $platform

    if {[::InstallJammer::ArchiveExists $platform]} {
        ::InstallJammer::Build$platform
        ::InstallJammer::FinishBuild $conf(buildErrors)
        return
    }

    set cmdargs [list]

    set conf(main)     [::InstallJammer::BuildDir ${platform}-main.tcl]

    set conf(fileManifest) [::InstallJammer::BuildDir ${platform}.files]
    set conf(packManifest) [::InstallJammer::BuildDir ${platform}-manifest.txt]

    set conf(fileDataFile) [::InstallJammer::BuildDir ${platform}-files.tcl]

    set conf(tmpExecutable) [::InstallJammer::BuildDir ${platform}-build.tmp]
    file delete -force $conf(tmpExecutable)

    set executable [::InstallJammer::SubstText [$platform get Executable]]
    set conf(outputDir)  [::InstallJammer::OutputDir]
    set conf(archiveFiles)  {}
    set conf(buildArchives) [$platform get BuildSeparateArchives]
    if {$conf(buildArchives)} {
        set conf(setupFileList) {}
        if {![info exists conf(OutputDir)]} {
            set conf(outputDir) [file join $conf(outputDir) $platform]
        }
    }
    set conf(executable) [file join $conf(outputDir) $executable]

    file mkdir [::InstallJammer::BuildDir] $conf(outputDir)

    FileProgress     0
    PlatformProgress 0

    set text [PlatformText $platform]
    BuildLog "Building $text install...  "

    ::InstallJammer::StatusPrefix "Building $text install...  "

    set rebuildOnly 0
    if {$conf(rebuildOnly)} {
	if {![file exists $conf(executable)]} {
	    BuildLog "Install does not exist.  Doing a full build..."
	    set rebuildOnly 0
	} else {
	    BuildLog "Rebuilding without repackaging files..."
	    set rebuildOnly 1
	}
    }

    if {$platform eq "Windows"} {
        set admin [$platform get RequireAdministrator]
        set last  [$platform get LastRequireAdministrator]
        if {$admin ne $last} {
            BuildLog "Require Administrator changed.  Doing a full build..."
            set rebuildOnly 0
        }
        $platform set LastRequireAdministrator $admin
    }

    BuildLog "Building main.tcl..."

    set fp [open $conf(main) w]
    fconfigure $fp -translation lf

    puts $fp [read_file [file join $conf(lib) header.tcl]]

    puts $fp "namespace eval ::InstallAPI {}"
    puts $fp "namespace eval ::InstallJammer {}"
    puts $fp "set conf(version)     $conf(Version)"
    puts $fp "set info(Platform)    [list $platform]"
    puts $fp "set info(InstallerID) [list [::InstallJammer::uuid]]"

    set langs [::InstallJammer::GetActiveLanguages]
    puts $fp "array set ::InstallJammer::languagecodes [list $langs]"

    ::InstallJammer::CheckForBuildStop

    array set buildInfo [VirtualTextData]

    foreach var $conf(InstallVars) {
        set buildInfo($var) $info($var)
    }

    foreach var $conf(PlatformVars) {
        if {[$platform get $var value]} { set buildInfo($var) $value }
    }

    if {$info(InstallPassword) ne ""} {
        set buildInfo(InstallPasswordEncrypted) [sha1hex $info(InstallPassword)]
    }

    puts $fp [ReadableArrayGet buildInfo info]

    puts $fp [::InstallJammer::GetCommandLineOptionData -build 1 \
                -setup Install -includedebug $info(IncludeDebugging)]

    ::InstallJammer::CheckForBuildStop

    ## Make a dummy call to SaveFileGroups to find out what file groups
    ## we're going to use in this install.  This sets up the data so
    ## that GetSetupFileList will get only the files we're using.
    ::InstallJammer::SaveFileGroups -build 1 -platform $platform

    ## Build the file list first.  Getting a list of all the files will
    ## update the group objects with their proper sizes for when we
    ## save them in the install.

    ## If we're doing a quick build and we have existing file data,
    ## we'll just use that instead of rebuilding it.  Otherwise,
    ## we'll build the file data and then store it out to a file for
    ## next time.
    if {$rebuildOnly && [file exists $conf(fileDataFile)]
        && [file exists $conf(executable)]} {
        set fileData [read_file $conf(fileDataFile)]
    } else {
        set rebuildOnly 0
        if {$conf(refreshFiles)} {
            set conf(refreshFiles) 0
            ::InstallJammer::RefreshFileGroups
        }

        BuildLog "Getting file list..."
        set filelist {}
        ::InstallJammer::GetSetupFileList -platform $platform \
            -errorvar missing -listvar filelist -procvar fileData

        set ofp [open $conf(fileDataFile) w]
        fconfigure $ofp -translation lf
        puts  $ofp $fileData
        close $ofp
    }

    ::InstallJammer::CheckForBuildStop

    if {!$rebuildOnly} {
        if {[llength $missing]} {
            set action $info(BuildFailureAction)
            if {$conf(cmdline)} {
                set action $info(CommandLineFailureAction)
            }
	    set fail [string match "*Fail*" $action]

            foreach file $missing {
		BuildLog "File '$file' does not exist!" -tags error
		if {!$fail} { incr conf(totalBuildErrors) -1 }
            }

	    if {$fail} {
                close $fp
                ::InstallJammer::FinishBuild 1
                return
            }
        }

        foreach {group file} [::InstallJammer::BuildFileManifest $filelist] {
            lappend arcFiles  $file
            lappend arcGroups $group
        }

        if {[info exists arcFiles]} {
            puts $fp "set info(ArchiveFileList) [list $arcFiles]"
            puts $fp "set info(ArchiveGroupList) [list $arcGroups]"
        }
    }

    ::InstallJammer::CheckForBuildStop

    BuildLog "Saving install information..."

    ## Save all the file groups, components and setup types inside a
    ## proc so that we can call it once the system has been initialized
    ## and not when the install is sourced in.
    set    setupData "proc ::InstallJammer::InitSetup {} \{\n"
    append setupData [::InstallJammer::SaveBuildInformation -platform $platform]
    append setupData "\n\}"

    ::InstallJammer::CheckForBuildStop

    ## Store properties.
    set propertyData [::InstallJammer::SaveProperties -build 1 -setup Install \
        -activeonly 1 -includecomments $info(IncludeDebugging) \
        -array ::InstallJammer::Properties]
    puts $fp $propertyData

    ## Build a string of procs and other data that we want to check
    ## for API calls.  When we build the API data, we will only
    ## include procs that have been called somewhere in our install.
    append apiCheckData $propertyData\n

    ## Store InstallJammer files in the main.tcl file.  This means that in
    ## order to update the install, we only have to overwrite one file.
    ## It also makes it easy to delete the entire install contents with
    ## just one file.
    set installBaseFiles [list common.tcl unpack.tcl]
    if {$platform ne "Windows"} { lappend installBaseFiles console.tcl }
    foreach file $installBaseFiles {
	set filedata($file) [read_file [::InstallJammer::LibDir $file]]
    }

    upvar 0 filedata(common.tcl) commonTcl

    set filedata(files.tcl)      $fileData
    set filedata(setup.tcl)      $setupData
    set filedata(gui.tcl)        [BuildGuiData]
    set filedata(components.tcl) [::InstallJammer::BuildComponentData Install]

    ## Check for an uninstaller and add it if needed.
    set actions [::InstallJammer::GetActionList Install 1]
    if {[lsearch -exact $actions "InstallUninstaller"] > -1} {
	set filedata(uninstall.tcl) [BuildUninstallData buildInfo]
    }

    if {"InstallInstallTool" in $actions} {
        set file "installtool.tcl"
	set filedata($file) [read_file [::InstallJammer::LibDir $file]]
    }

    ::InstallJammer::CheckForBuildStop

    foreach file [lremove [ThemeFiles Install] init.tcl main.tcl] {
	puts $fp [ShrinkFile [::InstallJammer::ThemeDir Install/$file]]
    }

    foreach file [lremove [ThemeFiles Common] setup.tcl] {
        puts $fp [ShrinkFile [::InstallJammer::ThemeFile Common $file]]
    }

    set installCode [ShrinkFile [::InstallJammer::LibDir install.tcl]]

    append apiCheckData $installCode\n

    ::InstallJammer::CheckForBuildStop

    ## Store pane proc data.
    set windowProcData [::InstallJammer::GetWindowProcData \
        -build 1 -setups Install -activeonly 1]
    puts $fp $windowProcData

    append apiCheckData $windowProcData\n
    append apiCheckData [array get filedata]\n

    ## Add the install API routines.
    uplevel #0 [list source [file join $conf(lib) installapi.tcl]]
    append commonTcl "\n[::InstallJammer::BuildAPIData apiCheckData]"

    foreach file [array names filedata] {
        set filedata($file) [ShrinkCode $filedata($file)]
    }

    ## Store all of the stored file data.
    puts $fp "array set ::InstallJammer::files [list [array get filedata]]"
    puts $fp "::InstallJammer::SourceCachedFile common.tcl"

    ## Add the install theme's inititialization code.
    puts $fp [ShrinkFile [::InstallJammer::ThemeDir Install/init.tcl]]\n

    set installComponentData [::InstallJammer::SaveInstallComponents \
        -build 1 -activeonly 1 -setup Install -actiongroupvar actionGroupData]

    ## Store the action groups before the install routines because some
    ## of them can be executed during the install startup.
    puts $fp $actionGroupData

    ## Store the standard procedures used for all installs.
    puts $fp $installCode
    
    ::InstallJammer::CheckForBuildStop

    ## Store the component objects in the install.
    puts $fp $installComponentData

    set main [::InstallJammer::ThemeDir Install/main.tcl]
    if {[file exists $main]} {
        ## Add the install theme's main code last.
        puts $fp [ShrinkFile [::InstallJammer::ThemeDir Install/main.tcl]]
    } else {
        puts $fp "::InstallJammer::InstallMain"
    }

    close $fp

    ## If we're only building main.tcl, we don't need to do the rest.
    if {$conf(buildMainTclOnly)} { return }

    set execdir [file dirname $conf(executable)]
    if {![file exists $execdir]} { file mkdir $execdir }
    file delete -force [file join $execdir runtime]
    if {!$rebuildOnly} {
    	if {[catch { file delete -force $conf(tmpExecutable) }]} {
	    set msg "Failed to delete $conf(tmpExecutable)."
	    append msg "  The program may be running."
	    ::InstallJammer::Error -title "Error Building" -message $msg
	    ::InstallJammer::FinishBuild 1
	    return
	}
    }

    ::InstallJammer::CheckForBuildStop

    BuildLog "Building install..."

    ## If we're only rebuilding the interface, and we're running from
    ## an installkit, we can make this really short and sweet.
    if {$rebuildOnly && [info exists ::installkit::root]} {
        set files [list $conf(main) [::InstallJammer::BuildDir messages]]
        set names [list main.tcl catalogs/messages]
        installkit::addfiles $conf(executable) $files $names
	::InstallJammer::FinishBuild
	return
    }

    set buildScript [file join $conf(lib) dobuild.tcl]

    set cmd [list [BuildBinary] $buildScript -o $conf(tmpExecutable)]
    eval lappend cmd $cmdargs
    lappend cmd --output $conf(outputDir)

    lappend cmd -level $info(CompressionLevel)

    lappend cmd -catalog [::InstallJammer::BuildDir messages]

    if {$info(InstallPassword) ne ""} {
        lappend cmd -password \
            [::InstallJammer::SubstText $info(InstallPassword)]
    }

    ## Include the InstallJammer package files.
    lappend cmd -package [file join $conf(lib) packages InstallJammer]

    eval lappend cmd [::InstallJammer::BuildPackageData $platform]

    if {$platform eq "Windows"} {
        ## If the user wants to include the TWAPI extension, or we
        ## find a twapi command anywhere in our code, we want to
        ## include the TWAPI extension.
        if {[lsearch -glob $cmd "*twapi"] < 0
            && [::InstallJammer::IncludeTWAPI $apiCheckData]} {
            ## Add the TWAPI extension.
            set dir [file join $conf(pwd) Binaries $platform lib twapi]
            if {[file exists $dir]} { lappend cmd -package $dir }
        }

        if {[lsearch -glob $cmd "*ffidl"] < 0
            && [::InstallJammer::IncludeFfidl $apiCheckData]} {
            set dir [file join $conf(pwd) Binaries $platform lib ffidl]
            if {[file exists $dir]} { lappend cmd -package $dir }
        }

        if {[$platform get WindowsIcon icon]} {
            set file [::InstallJammer::FindFile $icon $conf(winico)]
	    if {![file exists $file]} {
		BuildLog "Windows Icon '$icon' does not exist." -tags error
	    } else {
		lappend cmd -icon $file
	    }
	}

        lappend cmd -company [::InstallJammer::SubstText $info(Company)]
        lappend cmd -copyright [::InstallJammer::SubstText $info(Copyright)]
        lappend cmd -fileversion \
            [::InstallJammer::SubstText $info(InstallVersion)]
        lappend cmd -productname [::InstallJammer::SubstText $info(AppName)]
        lappend cmd -productversion [::InstallJammer::SubstText $info(Version)]

        set desc [::InstallJammer::SubstText [$platform get FileDescription]]
        if {$desc ne ""} { lappend cmd -filedescription $desc }
    }

    if {$rebuildOnly} {
	file rename $conf(executable) [file join $execdir runtime]
	lappend cmd -w [file join $execdir runtime]
    } else {
        if {[file exists $conf(packManifest)]} {
	    lappend cmd -f $conf(packManifest)
        }

        if {$conf(buildArchives) && [file exists $conf(fileManifest)]} {
            lappend cmd --archive-manifest $conf(fileManifest)
        }

	lappend cmd -w [InstallKitStub $platform]
    }
    lappend cmd $conf(main)

    ::InstallJammer::CheckForBuildStop

    if {[threaded]} {
        thread::errorproc ::InstallJammer::BuildOutput
        set tid [installkit::newThread thread::wait]
        thread::send $tid [list set ::argv [lrange $cmd 2 end]]
        thread::send $tid [list lappend ::auto_path $conf(pflib)]
        thread::send $tid [list source $conf(lib)/common.tcl]
        thread::send -async $tid [list source $buildScript]
    } else {
	set fp [open "|$cmd"]
	set conf(buildPID) [pid $fp]
	fconfigure $fp -blocking 0
	fileevent $fp readable [list ::InstallJammer::ReadBuild $fp]
    }

    ::InstallJammer::CheckForBuildStop
}

proc ::InstallJammer::BuildZipArchive {} {
    global conf
    global info

    set archive ZipArchive

    ::InstallJammer::StatusPrefix "Building zip archive...  "

    BuildLog "Building zip archive..."

    if {$conf(refreshFiles)} {
        set conf(refreshFiles) 0
        ::InstallJammer::RefreshFileGroups
    }

    BuildLog "Getting file list..."
    set filelist {}
    ::InstallJammer::GetSetupFileList -platform $archive \
        -checksave 0 -listvar filelist -includedirs 0 -forarchive 1

    if {![llength $filelist]} {
        BuildLog "No files to archive..." -tags error
        return
    }

    set level  [$archive get CompressionLevel]
    set output [::InstallJammer::SubstText [$archive get OutputFileName]]
    set output [::InstallJammer::OutputDir $output]

    set conf(executable)    $output
    set conf(tmpExecutable) $output.tmp

    if {[file exists $output]} { file delete -force $output }

    set map [list]
    foreach {string value} [$archive get VirtualTextMap] {
        lappend map $string [::InstallJammer::SubstText $value]
    }

    if {[catch { ::miniarc::open zip $conf(tmpExecutable) -level $level } fp]} {
        BuildLog "Error opening zip file for output! $fp" -tags error
        BuildLog $fp -tags error
        return
    }

    set filesdone    0
    set totalfiles   [llength $filelist]
    set lastpercent  0
    set totalpercent 100

    foreach list $filelist {
        lassign $list file dest permissions
        set dest [string map $map $dest]

        if {![info exists done($dest)]} {
            ::InstallJammer::LogPackedFile $file

            if {[catch { ::miniarc::addfile $fp $file -name $dest } error]} {
                BuildLog "Error archiving file '$file': $error" -tags error
                return
            }
            set done($dest) 1

            set pct [expr {([incr filesdone] * $totalpercent) / $totalfiles}]

            if {$pct != $lastpercent} {
                PlatformProgress $pct
                set lastpercent $pct
                update
            }
        }
    }

    ::miniarc::close $fp
}

proc ::InstallJammer::BuildTarArchive {} {
    global conf
    global info

    set archive TarArchive

    ::InstallJammer::StatusPrefix "Building tar archive...  "

    BuildLog "Building tar archive..."

    if {$conf(refreshFiles)} {
        set conf(refreshFiles) 0
        ::InstallJammer::RefreshFileGroups
    }

    BuildLog "Getting file list..."
    set filelist {}
    ::InstallJammer::GetSetupFileList -platform $archive \
        -checksave 0 -listvar filelist -includedirs 1 -forarchive 1

    set output [::InstallJammer::SubstText [$archive get OutputFileName]]
    set output [::InstallJammer::OutputDir $output]

    set level [$archive get CompressionLevel]
    if {$level == 0 && [string match "*.gz" $output]} {
        set output [file root $output]
    }

    if {[file exists $output]} { file delete -force $output }

    set conf(executable) $output
    set conf(tmpExecutable) $output.tmp

    if {![llength $filelist]} {
        BuildLog "No files to archive..." -tags error
        return
    }

    set map [list]
    foreach {string value} [$archive get VirtualTextMap] {
        lappend map $string [::InstallJammer::SubstText $value]
    }

    if {[catch { ::miniarc::open tar $conf(tmpExecutable) } fp]} {
        BuildLog "Error opening tar file for output! $fp" -tags error
        BuildLog $fp -tags error
        return
    }

    set filesdone    0
    set totalfiles   [llength $filelist]
    set lastpercent  0
    set totalpercent 100

    if {$level > 0} { set totalpercent 95 }

    set defdirmode  [$archive get DefaultDirectoryPermission]
    set deffilemode [$archive get DefaultFilePermission]
    foreach list $filelist {
        lassign $list file dest permissions
        set dest [string map $map $dest]

        if {$permissions eq ""} {
            if {[file isdirectory $file]} {
                set permissions $defdirmode
            } else {
                set permissions $deffilemode
            }
        }

        if {![info exists done($dest)]} {
            ::InstallJammer::LogPackedFile $file

            if {[catch { ::miniarc::addfile $fp $file \
                        -name $dest -permissions $permissions } error]} {
                BuildLog "Error archiving file '$file': $error" -tags error
                return
            }
            set done($dest) 1

            set pct [expr {([incr filesdone] * $totalpercent) / $totalfiles}]

            if {$pct != $lastpercent} {
                PlatformProgress $pct
                set lastpercent $pct
                update
            }
        }
    }

    ::miniarc::close $fp

    if {$level > 0} {
        BuildLog "Gzipping tar archive..."
        ::miniarc::gzip -delete 1 -level $level $conf(tmpExecutable) $output
    }
}
