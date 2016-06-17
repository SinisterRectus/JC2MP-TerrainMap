class 'TerrainMap'

function TerrainMap:__init()
	Network:Subscribe('TeleportToPosition', self, self.OnTeleportToPosition)
end

function TerrainMap:OnTeleportToPosition(args, sender)
	sender:SetPosition(args.position)
end

TerrainMap = TerrainMap()
