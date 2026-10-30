--!strict
--@client
local engine=require("@moonbase/engine")
local avatar=require("@moonbase/avatar")
local api=require("@es/api")
local models=require("@es/models")
local M={}
-- Variation ids for players without an outfit of their own (editor test
-- players): the runway project's default look.
M.STARTER=table.freeze({241120,-2})
-- Correct ordinary canvas padding, but keep partial/head-only outfits near
-- their authored height instead of dropping their lowest accessory to the floor.
function M.groundOffset(bounds: engine.Bounds3?): number
	return if bounds then -math.clamp(bounds.min.y, 0, 0.2) else 0
end
function M.url(ids: {number}, uncropped: boolean?): string
	local url=models.Item.getImageUrl({variationIds=ids,withAnimation=false,crop=false})
	-- Omitting m still trims the PNG. The renderer needs the explicit full canvas;
	-- UI thumbnails can retain the CDN's trimmed default.
	return url..(if uncropped then "?m=0" else "")
end
function M.render(ids: {number}): engine.AvatarRenderData
	-- Composite renders use the standard uncropped 221x340 avatar canvas. Keeping
	-- the complete image preserves behind-body layers and wider accessories.
	return engine.AvatarRenderData({width=221,height=340,anchorX=110.5,anchorY=340,items={
		engine.AvatarItemRenderData({frames={engine.AvatarFrameRenderData({image=M.url(ids,true),width=221,height=340})}}),
	}})
end
-- The composite is a single frame, so animated pieces stand still in it. An
-- outfit with an animated piece is drawn in layers instead, one per variation
-- with its own frames (a texture per piece rather than one per avatar, so only
-- those outfits pay for it). By outfit; false keeps the composite.
local layers: {[string]: engine.AvatarRenderData | false}={}
-- Fetched variations with their frames, shared by every outfit wearing them
-- (false: not returned). `fetching` marks ids still in flight.
local pieces: {[number]: models.ItemVariation | false}={}
local fetching: {[number]: boolean}={}
local function fetch(ids: {number})
	api.rest:query("item/variation")
		:withParsers({multi=models.ItemVariation.fromJsonAll, single=models.ItemVariation.fromJsonOne})
		:filter({api.Search.includes("id", ids)})
		:join({"item", "itemVariationFrames"})
		:limit(0)
		:all()
		:andThen(function(found: {read models.ItemVariation})
			for _, v in found do
				if v.id then pieces[v.id :: number]=v end
			end
			for _, id in ids do
				fetching[id]=nil
				if pieces[id]==nil then pieces[id]=false end
			end
		end, function(err: unknown, _stack: unknown)
			for _, id in ids do
				fetching[id]=nil
				pieces[id]=false
			end
			print("Outfit pieces failed to load, keeping the still image: "..tostring(err))
		end)
end
-- Outfits list their pieces frontmost first, the order the renderer draws.
-- Ids up to 0 are the built-in skins and faces.
local function assemble(ids: {number}): engine.AvatarRenderData | false
	local ordered: {models.ItemVariation}, animated={}, false
	for _, id in ids do
		local v: models.ItemVariation?=nil
		if id<=0 then
			local ok, skin=pcall(models.Item.getDefaultVariation, id)
			v=if ok then skin else nil
		else
			v=pieces[id] or nil
		end
		if not v then return false end
		if #v.itemVariationFrames>1 then animated=true end
		table.insert(ordered, v)
	end
	if not animated then return false end
	local ok, data=pcall(avatar.EverskiesAvatar.fromVariations, {variations=ordered})
	return if ok then data else false
end
-- Layered render data for an outfit with an animated piece: nil while its
-- pieces load (the first call fetches the ones not known yet), false when the
-- composite will do.
function M.layered(ids: {number}): (engine.AvatarRenderData | false)?
	local key=table.concat(ids, ",")
	local known=layers[key]
	if known~=nil then return known end
	local missing: {number}, waiting={}, false
	for _, id in ids do
		if id>0 and pieces[id]==nil then
			waiting=true
			if not fetching[id] then
				fetching[id]=true
				table.insert(missing, id)
			end
		end
	end
	if #missing>0 then fetch(missing) end
	if waiting then return nil end
	local data=assemble(ids)
	layers[key]=data
	return data
end
return table.freeze(M)
