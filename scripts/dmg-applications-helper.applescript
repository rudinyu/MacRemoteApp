on run
	openUserApplicationsFolder()
end run

on open droppedItems
	ensureUserApplicationsFolder()
	set applicationsFolder to userApplicationsFolder()
	tell application "Finder"
		repeat with droppedItem in droppedItems
			set droppedAlias to droppedItem as alias
			set itemInfo to info for droppedAlias
			if (kind of itemInfo is "Application") or (name extension of itemInfo is "app") then
				duplicate droppedAlias to applicationsFolder with replacing
			end if
		end repeat
	end tell
	openUserApplicationsFolder()
end open

on ensureUserApplicationsFolder()
	set applicationsPath to userApplicationsPOSIXPath()
	if pathHasFlag(applicationsPath, "-L") then
		error "MacRemoteApp refuses to use a symlink as ~/Applications. Replace it with a real folder, then retry."
	end if
	if pathHasFlag(applicationsPath, "-e") and not pathHasFlag(applicationsPath, "-d") then
		error "MacRemoteApp refuses to use a non-directory as ~/Applications. Replace it with a real folder, then retry."
	end if
	tell application "Finder"
		set applicationsFolder to userApplicationsFolder()
		if not (exists applicationsFolder) then
			make new folder at (path to home folder from user domain) with properties {name:"Applications"}
		end if
	end tell
end ensureUserApplicationsFolder

on openUserApplicationsFolder()
	ensureUserApplicationsFolder()
	tell application "Finder"
		set applicationsFolder to userApplicationsFolder()
		open applicationsFolder
	end tell
end openUserApplicationsFolder

on userApplicationsFolder()
	return ((path to home folder from user domain) as text) & "Applications:"
end userApplicationsFolder

on userApplicationsPOSIXPath()
	return (POSIX path of (path to home folder from user domain)) & "Applications"
end userApplicationsPOSIXPath

on pathHasFlag(pathString, flag)
	try
		do shell script "/usr/bin/test " & flag & " " & quoted form of pathString
		return true
	on error
		return false
	end try
end pathHasFlag
