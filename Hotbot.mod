<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
	<UiMod name="Hotbot" version="1.2.1" date="30/08/2026">
		<Author name="TUP" email="" />
		<Description text="Single-button HoT applicator. Tracks HoT coverage across roster members or nearby friendly players. Per-career ability ID configured in Config.lua." />
		<VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />

		<Dependencies>
			<Dependency name="EASystem_LayoutEditor" />
			<Dependency name="LibGroup" />
		</Dependencies>

		<Files>
			<File name="Config.lua" />
			<File name="Gui.xml" />
			<File name="Core.lua" />
		</Files>

		<OnInitialize>
			<CreateWindow name="HotbotFrame" show="false" />
			<CallFunction name="Hotbot.OnLoadComplete" />
		</OnInitialize>

		<OnUpdate>
			<CallFunction name="Hotbot.OnUpdate" />
		</OnUpdate>

		<OnShutdown>
			<CallFunction name="Hotbot.OnUnload" />
		</OnShutdown>

		<WARInfo>
			<Categories>
				<Category name="HEALER" />
			</Categories>
			<Careers>
				<Career name="RUNE_PRIEST" />
				<Career name="ZEALOT" />
				<Career name="ARCHMAGE" />
				<Career name="SHAMAN" />
				<Career name="WARRIOR_PRIEST" />
				<Career name="DISCIPLE" />
			</Careers>
		</WARInfo>
	</UiMod>
</ModuleFile>
