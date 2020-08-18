-- all the render targets used for reflections will use this resolution
-- 1/4 the current resolution is usually a good balance between performance and quality
local rtW, rtH = ScrW() / 4, ScrH() / 4

-- these materials / textures / colors are used when rendering the alpha masks for each plane
local black, white       = Material "tools/toolsblack", Material "color"
local blacktex, whitetex = black:GetTexture "$basetexture", white:GetTexture "$basetexture"
local blackvec, whitevec = Vector(0, 0, 0), Vector(1, 1, 1)

-- globals that are used constantly in rendering can be localized to speed things up

local cam                 = cam
local cam_PopModelMatrix  = cam.PopModelMatrix
local cam_PushModelMatrix = cam.PushModelMatrix

local render                          = render
local render_Clear                    = render.Clear
local render_CullMode                 = render.CullMode
local render_SetMaterial              = render.SetMaterial
local render_DrawQuadEasy             = render.DrawQuadEasy
local render_OverrideBlend            = render.OverrideBlend
local render_PopCustomClipPlane       = render.PopCustomClipPlane
local render_PushCustomClipPlane      = render.PushCustomClipPlane
local render_SetLightingMode          = render.SetLightingMode
local render_PopRenderTarget          = render.PopRenderTarget
local render_BlurRenderTarget         = render.BlurRenderTarget
local render_PushRenderTarget         = render.PushRenderTarget
local render_OverrideDepthEnable      = render.OverrideDepthEnable
local render_DrawTextureToScreen      = render.DrawTextureToScreen
local render_OverrideColorWriteEnable = render.OverrideColorWriteEnable

-- these are the various render targets that work together to form the resulting reflections
-- each render target serves specific purpose:
--
-- canvas - the final texture that will be blended with the default render target
--          this has all relevant plane reflections "painted" onto it
--
-- worldmask - this represents the reflectivity of every surface on worldspawn
--
-- planemask - same as worldmask, except it only applies to a specific plane of surfaces
--
local worldmask = GetRenderTarget("_rt_PWR_WorldMask_"..rtW.."x"..rtH, ScrW() / 2, ScrH() / 2)
local planemask = GetRenderTarget("_rt_PWR_PlaneMask_"..rtW.."x"..rtH, ScrW() / 2, ScrH() / 2)
local canvas    = GetRenderTarget("_rt_PWR_Canvas_"..rtW.."x"..rtH, rtW, rtH)

-- bet you can't guess what this is for
local world = game.GetWorld()

-- each reflective plane and materials will be cached and used later in rendering
-- non-reflective materials are also cached to be used in alpha masks
local planes = {}
local mats   = {}
local _mats  = {}

-- let's cache the stuff mentioned above by iterating through EVERY surface on worldspawn
for i, surf in pairs(world:GetBrushSurfaces()) do
	-- there are a few surfaces we don't even want to consider for reflections:
	-- • missing / invalid "$reflectworld" VMT key value
	-- • forms an invalid shape
	-- • textured as nodraw
	-- • textured as sky
	
	if surf:IsSky() || surf:IsNoDraw() then continue end
	
	local verts = surf:GetVertices()
	
	if #verts < 3 then continue end
	
	local _mat = surf:GetMaterial()
	local name = _mat:GetName()
	local tex  = _mat:GetTexture "$basetexture"
	local col  = _mat:GetVector "$color"
	local tint = _mat:GetVector "$reflectworldtint" || whitevec
	
	local mat  = {
		mat    = _mat,
		tex    = tex,
		name   = name,
		tint   = tint,
		col    = col,
	}

	if tobool(_mat:GetInt "$reflectworld") then
		mats[name] = mat
	else
		_mats[name] = mat continue
	end
	
	-- now some useful information about this surface's plane will be cached (if not already)
	
	local dir  = (verts[3] - verts[1]):Cross(verts[2] - verts[1]):GetNormalized()
	dir.x      = tostring(dir.x) == "-0" && 0 || dir.x
	dir.y      = tostring(dir.y) == "-0" && 0 || dir.y
	dir.z      = tostring(dir.z) == "-0" && 0 || dir.z
	local dist = dir:Dot(verts[1])
	local id   = dir.x..","..dir.y..","..dir.z..","..dist
	
	if planes[id] then continue end
	
	local rt    = GetRenderTarget("_rt_PWR_Plane_"..id.."_"..rtW.."x"..rtH, rtW, rtH)
	local pos   = dir * dist
	local ang   = dir:Angle()
	local right = ang:Right()
	local up    = ang:Up()
	local mat   = Matrix()
	mat:SetTranslation(dir * ((dist * 2) + 1))
	mat:SetForward(dir)
	mat:SetRight(right)
	mat:SetUp(up)
	mat:Rotate(ang)
	mat:Rotate(Angle(180, 180, 0))
	mat:Scale(Vector(-1, -1, -1))
	dist = -dist
	
	planes[id] = planes[id] || {
		pos    = pos,
		ang    = ang,
		dir    = dir,
		dist   = dist,
		mat    = mat,
		rt     = rt,
	}
end

-- print some information to the console for debugging
-- comment these out for production use

print "REFLECTIVE PLANES"
print "--------------------"
PrintTable(planes)

print "\nREFLECTIVE MATERIALS"
print "--------------------"
PrintTable(mats)

print "\nNON-REFLECTIVE MATERIALS"
print "------------------------"
PrintTable(_mats)

-- this is where the reflections are going to be rendered
-- at this point in the render stack, world stuff (worldspawn, skybox etc) has been drawn, but not dynamic stuff yet (entities, effects etc)
-- in other words, the reflections will be drawn over the world, but be drawn over by every other opaque / translucent renderable
hook.Add("PreDrawOpaqueRenderables", "gmpwr", function()
	-- the canvas texture will be the first render target in the stack
	render_PushRenderTarget(canvas)
		render_Clear(0, 0, 0, 0, true, true)
		
		render_PushRenderTarget(worldmask)
			render_Clear(0, 0, 0, 0, true, true)
			
			-- each world material is modified to use a grayscale texture (black - white) to represent their reflectivity
			-- FIXME: figure out how to tint the white texture when lighting is disabled ($color isn't working right now)
			
			for i, mat in pairs(mats) do
				mat.mat:SetTexture("$basetexture", whitetex)
				mat.mat:SetVector("$color", mat.tint)
			end for i, mat in pairs(_mats) do
				mat.mat:SetTexture("$basetexture", blacktex)
			end
			
			render_SetLightingMode(2)
				world:DrawModel()
			render_SetLightingMode(0)
			
			for i, mat in pairs(mats) do
				mat.mat:SetTexture("$basetexture", mat.tex)
				mat.mat:SetVector("$color", mat.col)
			end for i, mat in pairs(_mats) do
				mat.mat:SetTexture("$basetexture", mat.tex)
			end
			
			-- the world mask is set up, switch to the plane mask now
			render_PushRenderTarget(planemask)
				render_Clear(0, 0, 0, 0, true, true)	
				
				-- draw only the world's depth to the texture, so that the alpha mask can still respect the world's depth
				render_OverrideColorWriteEnable(true, false)
					world:DrawModel()
				render_OverrideColorWriteEnable(false, false) 
				
				local eyepos = EyePos()
				
				for i, plane in pairs(planes) do
					-- simple but effective optimization to not bother processes planes that are impossible to see (behind them)
					if -eyepos:Dot(plane.dir) > plane.dist then continue end
				
					-- flush the previous mask that was drawn (black texture fill)
					render_DrawTextureToScreen(blacktex)
					
					-- draw the plane by "cutting" it out with white / black planes 
					-- FIXME: there must be a way to prevent the "gap" created as a result of both quads technically being on different planes
					render_OverrideDepthEnable(true, false)
						render_SetMaterial(white)
						render_DrawQuadEasy(plane.pos + plane.dir * .2, plane.dir, 9999, 9999)
						render_SetMaterial(black)
						render_DrawQuadEasy(plane.pos - plane.dir * .2, plane.dir, 9999, 9999)
					render_OverrideDepthEnable(false, false)
					
					-- exclude any non-reflective materials from the plane mask using the world mask
					render_OverrideBlend(true, BLEND_ZERO, BLEND_ZERO, BLENDFUNC_MIN)
						render_DrawTextureToScreen(worldmask)
					render_OverrideBlend(false)
					
					-- switch to the plane's render target
					render_PushRenderTarget(plane.rt)
						render_Clear(0, 0, 0, 0, true, true)
						
						-- render the world reflected along this plane
						cam_PushModelMatrix(plane.mat)
							render_CullMode(1)
								render_PushCustomClipPlane(-plane.dir, plane.dist)
									world:DrawModel()
								render_PopCustomClipPlane()
							render_CullMode(0)
						cam_PopModelMatrix()
						
						-- blend the reflective (white) areas of the alpha mask with the reflected world
						render_OverrideBlend(true, BLEND_ZERO, BLEND_ZERO, BLENDFUNC_MIN)
							render_DrawTextureToScreen(planemask)
						render_OverrideBlend(false)
						
						-- switch to the canvas texture for a moment to "paint" the resulting plane reflection onto the canvas
						render_PushRenderTarget(canvas)
							render_OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
								render_DrawTextureToScreen(plane.rt)
							render_OverrideBlend(false)
						render_PopRenderTarget()
					render_PopRenderTarget()
				end
			render_PopRenderTarget()
		render_PopRenderTarget()
		
		-- apply a blur effect to the canvas
		-- TODO: customize this somehow? (NOTE: ALL planes and materials MUST share this in order to not completely tank performance)
		render_BlurRenderTarget(canvas, 6, 6, 1)
		
		-- before blending the canvas with the default render target, the worldmask should be blended with the canvas to more accurately
		-- exlude non-reflection surfaces (as a result of blurring the canvas previously)
		render_OverrideBlend(true, BLEND_ZERO, BLEND_ZERO, BLENDFUNC_MIN)
			render_DrawTextureToScreen(worldmask)
		render_OverrideBlend(false)
	render_PopRenderTarget()
	
	-- finally blend the resulting reflections onto the screen!
	render_OverrideBlend(true, BLEND_SRC_COLOR, BLEND_ONE, BLENDFUNC_ADD)
		render_DrawTextureToScreen(canvas)
	render_OverrideBlend(false)
end)