--这是我的Lua扩展库的基础目录，我所有的Lua扩展库都在这个目录下，以方便加载
local pathToLuaExts = 'E:/lua/myluaexts'
package.path = string.format('%s;%s/?.lua;%s/lj_doc/?.lua;', package.path, pathToLuaExts, pathToLuaExts)

require('strext')
require('lj_base.base')

local parser = require('docparser')
local templ = require('template')

--参数中要包含有要生成文档的Lua代码所在的路径
if select('#', ...) == 0 then
	print('no input path')
	return 
end

--解析参数
local outdir = './'
local inputPath = ''
local menuFilepath = ''
local templateCode = ''
_G['AllTypes'] = { integer = '整数型', number = '小数型', string = '字符串型', boolean = '布尔型', r = '只读', w = '只写', rw = '读写' }

for i = 1, select('#', ...), 2 do
	local nm, nextarg = select(i, ...), select(i + 1, ...)
	if nm == '-menu' then
		menuFilepath = nextarg
	elseif nm == '-in' then
		inputPath = nextarg:gsub('\\', '/')
		local lastch = inputPath:sub(#inputPath, #inputPath)
		if lastch ~= '/' and lastch ~= '\\' then
			inputPath = inputPath .. '/'
		end
		
	elseif nm == '-out' then
		outdir = nextarg:gsub('\\', '/')
		local lastch = outdir:sub(#outdir, #outdir)
		if lastch ~= '/' and lastch ~= '\\' then
			outdir = outdir .. '/'
		end
		
	elseif nm == '-template' then
		templateCode = io.fullfrom(nextarg, 'string')
	end
end

local env = setmetatable({ mainmCodes = '' }, { __index = _G })

--转换源文件名为输出的路径加文件名
function convertFilename(sourceFilename, linkit)
	local filepath = sourceFilename
	local fdir, fname = filepath:match('(.*/)(.*)')

	fdir = fdir:gsub('//', '/')	
	fdir = fdir:sub(#inputPath + 1, -2):gsub('/', '_')
	fname = fname:gsub('.lua', '.html')
	
	if linkit then
		return fdir .. '_' .. fname
	end
		
	return fname, fdir
end
--组合出输出的完整路径+文件名
function makeOutFilename(fdir, fname)
	if fdir and #fdir > 0 then
		return outdir .. fdir .. '_' .. fname
	end
	return outdir .. fname
end

--解析文本中的特殊指令并生成相应的HTML返回
--[#link] 链接到指定的文档
function parseTextHtml(text)
	local start = 1
	local r = {}
	
	text = text:gsub('\\n', '<br/>')
	
	while true do
		local pos = text:find('[#', start, true)
		if pos then
			if text:byte(pos - 1) == 92 then
				--转义的不需要处理
				if pos - start > 1 then
					r[#r + 1] = text:sub(start, pos - 2)
				end
				
				start = pos
			else
				--生成链接
				local name, showname = nil, nil
				local end1 = text:find(']', pos + 2, true)
				
				if end1 then
					if text:byte(pos + 2) == 91 then
						local end2 = text:find(']', end1 + 1, true)
						if end2 then
							showname = text:sub(pos + 3, end1 - 1)
							name = text:sub(end1 + 1, end2 - 1)
						end
					else				
						name = text:sub(pos + 2, end1 - 1)
					end
				end
				
				if name then
					if pos > start then
						r[#r + 1] = text:sub(start, pos - 1)
					end

					start = pos + 3 + #name
					if showname then
						start = start + #showname + 2
					end

					local ok = false
					if string.cmp(name, 'http://', 7) == 0 then
						--按外链处理
						ok = true
						r[#r + 1] = string.format('<a href="%s" target="_blank" class="innerlink" title="点击即可在新窗口打开该链接">%s</a>', name, showname == nil and name or showname)
					else
						local findDoc = parser.AllDocs[name]
						if findDoc then
							--找到为一个Doc
							if not showname then
								showname = findDoc.title
							end
							
							ok = true
							r[#r + 1] = string.format('<a href="./%s" target="_self" class="innerlink" title="点击打开该页文档">%s</a>', convertFilename(findDoc.sourceFilename, true), showname == nil and name or showname)
						else
							--没有找到，那么就按模块名称+函数名称找
							local tkns = string.split(name, '.')
							if #tkns == 2 then
								local mod = parser.AllModules[tkns[1]]
								if mod then
									local dt = mod.indices[tkns[2]]
									if dt then
										ok = true
										r[#r + 1] = string.format('<a href="./%s#%s" target="_self" class="innerlink" title="函数功能简述：%s\n\n点击可跳转到该函数的详细说明">%s</a>', convertFilename(mod.sourceFilename, true), dt.name, dt.title, dt.name)
									end
								end
							end											
						end
					end
					
					if not ok then
						r[#r + 1] = string.format('<strong><font color="red">链接到 %s 失败</font></strong>', name)
					end
				else
					r[#r + 1] = text:sub(start, pos + 2)
					start = pos + 2
				end
			end
		else
			break
		end
	end
	
	if #text > start then
		r[#r + 1] = text:sub(start)
	end
	
	return table.concat(r, '')
end


--菜单代码递归生成函数
if #menuFilepath > 0 then	
	recursionMenu = function(node, pnode, level, totalCodes)
		local autoId = #totalCodes + 1	

		if node.childs then
			totalCodes[autoId] = string.format('{ id:%d, pId:%d, name:"%s", open:true, iconOpen:"css/diy/1_open.png", iconClose:"css/diy/1_close.png"},', autoId, pnode == nil and 0 or pnode.autoId, node.title)
			node.autoId = autoId
			
			for i = 1, #node.childs do
				recursionMenu(node.childs[i], node, level + 1, totalCodes)
			end
		else
			totalCodes[autoId] = string.format('{ id:%d, pId:%d, name:"%s", icon:"css/diy/2.png", target:"_self", url:"./%s.html" },', autoId, pnode == nil and 0 or pnode.autoId, node.title, node.link:gsub('[.]+', '_'))
		end
	end

	--读入菜单文件
	parser.scanPath(menuFilepath)
	
	--转换为菜单代码
	if #parser.AllMenus > 0 then
		--第1个总是主菜单
		env.mainmCodes = {}
		local mainm = parser.AllMenus[1]
		
		for i = 1, #mainm.childs do
			recursionMenu(mainm.childs[i], nil, 0, env.mainmCodes)
		end
		
		env.mainmCodes = table.concat(env.mainmCodes, "\n")
	end
end


--读入所有的代码文件
if #inputPath > 0 then
	if #templateCode < 1 then
		print('no template file')
		return
	end
	
	parser.scanPath(inputPath)
	
	function echoFuncDecls(func)
		local decl = '<ul>'
		if type(func.decls) == 'table' then
			for i = 1, #func.decls do
				decl = decl .. string.format('<li>%s(%s)</li>', func.name, func.decls[i])
			end			
		else
			decl = decl .. string.format('<li>%s(%s)</li>', func.name, func.decls)
		end
		
		return decl .. '</ul>'
	end
	
	function echoFuncStatics(func)
		local r = {}
		if func.typedecl == 'static' then
			r[#r + 1] = '静态函数'
		end
		if type(func.decls) == 'table' then
			r[#r + 1] = string.format('共有%d个重载', #func.decls)
		end
		if #func.params > 0 then
			r[#r + 1] = string.format('%d个参数解释', #func.params)
		else
			r[#r + 1] = '无参数'
		end
		if #func.returns > 0 then
			r[#r + 1] = string.format('%d个返回值', #func.returns)
		else
			r[#r + 1] = '无返回值'
		end
		return table.concat(r, '，')
	end
	
	--按照模板输出
	if parser.AllScanFiles > 0 then
		--先输出所有模块
		for modname,mod in pairs(parser.AllModules) do
			--[[print(string.format('module:[%s] in file "%s"\n', modname, mod.sourceFilename))

			for i,func in pairs(mod.funcs) do
				print('function: ', func.name)
				print('declare: ', echoFuncDecls(func))
				print('description: ', func.desc)
				if func.typedecl then print('typedecl: ', func.typedecl) end
				--print('return: ', func.rettype, func.retdesc)
				for pi,param in pairs(func.params) do
					print(string.format('\tparam: %d %s %s %s', pi, param.name, param.type, param.desc))
				end
				print('')
			end
			
			for i,static in pairs(mod.statics) do
				print('static: ', static.name, static.text, static.value)
			end
			
			for i,prop in pairs(mod.properties) do
				print('property: ', prop.name, prop.ability, prop.text, prop.value)
			end]]

			env.mod = mod
			env.doc = mod.withDoc
			if env.doc then
				env.doc.outputed = true
				env.modname = string.format('%s —— %s', modname, env.doc.title)
			else
				env.modname = #modname == 0 and '全局' or modname
			end

			local ffi = require('ffi')
			table.sort(mod.funcs, function(a, b)
				return ffi.C.strcmp(a.name, b.name) < 0 and true or false
			end)

			local fname, fdir = convertFilename(mod.sourceFilename)
			local fileCode = templ.compile(templateCode, env)
			io.dumpto(makeOutFilename(fdir, fname), fileCode)
		end

		--再输出所有纯Doc文档
		for docname,doc in pairs(parser.AllDocs) do
			if not doc.outputed then
				env.mod = nil
				env.doc = doc
				env.modname = doc.title

				local fname, fdir = convertFilename(doc.sourceFilename)
				local fileCode = templ.compile(templateCode, env)
				os.filedump(makeOutFilename(fdir, fname), fileCode)
			end
		end
	end
end