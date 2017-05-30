--[[
	AllModules以name为索引保存了所有的module的数据
	
	每一个module的结构如下所示：{
		name: 'string',
		funcs: { 函数1, 函数2, ... }
		statics: { { name=名称, value=值, text='静态1' }, { name=名称, text='静态2' }, ... }
		properties: { { name=名称, value=默认值, ability='rw', text='属性1' }, { name=名称, ability='r', text='属性2' }, ... }
		indices: { 名称=值, 名称=值, ... }	名称可能是函数，也可能是静态值
	}
	
	每一个function的结构如下所示：{
		name: 'replace',
		desc: '',
		title: '',
		samples: '示例代码'
		returns: { { 'type' = 'xx', 'desc' = 'xxxx' }, ... }
		decls: { }, 所有的定义形式,
		typedecl: nil|'static'，表示函数的特殊定义，如静态函数
		params: { { 'name', 'type', 'desc' }, { 'name', 'type', 'desc' }, ... }
	}
	
	每一个doc的结构如下所示：{
		title: '标题',
		name: '文档的链接名称，通过此名称就可以找到并链接文档',
		segments: {}  所有的段落内容，每一个段落的内容为一行
		samples: {}  指出哪些段落是示例代码段落
	}	
]]
module('docparser', package.seeall)

local fd = require('lj_base.fd')

AllScanFiles = 0
AllDocs = {}
AllMenus = {}
AllModules = {}
AllPropertyAbilities = { r = 1, w = 2, rw = 3 }
AllScanModes = { api = 'api', doc = 'doc', code = 'code', menu = 'menu' }
AllVarTypes = { ['...']=0,boolean=1,number=2,integer=3,string=4,['function']=5,table=6,userdata=7,lightuserdata=8,thread=9 }

function buildListDataOne(text, lt)
	table.insert(text, string.format('<%s>', lt.tag));
	
	for k=1, #lt.items do
		local it = lt.items[k]
		if it.child then
			table.insert(text, '<li>' .. it.text)
			buildListDataOne(text, it.child)
			table.insert(text, '</li>')
		else
			table.insert(text, string.format('<li>%s</li>', it.text));
		end
	end

	table.insert(text, string.format('</%s>', lt.tag));
end


--扫描并处理一个代码文件中的所有内容
function scanFile(filename)	
	--print('parse file:', filename)
	
	local lineCount, listIn, listLevel, listCurType, listData, menuData = 0, 0, 0, 0, {}, nil
	local samplesBegin, inComment = false, false
	local continueLineFunc, funcData = nil, nil
	local scanMode, moduleData = nil, nil	
	local minus = string.byte('-')	
	local collectSamples = 0	
	local staticText = nil
	local docData = nil
	
	local fetchFuncParams = function(line)	--将函数的参数列表按照()找出来并将参数字符串返回
		local paramsBegin = string.find(line, '(', 10, true)	
		local paramsEnd = string.find(line, ')', 11, true)
		if paramsBegin == nil or paramsEnd == nil or paramsEnd <= paramsBegin then
			error(string.format("file '%s' have error syntax in %u line with function define", filename, lineCount))
		end
		
		local typedecl = nil
		if string.sub(paramsEnd + 1, paramsEnd + 1) == ':' then
			typedecl = string.sub(paramsEnd + 2)
		end

		return string.trim(string.sub(line, paramsBegin + 1, paramsEnd - 1)), typedecl
	end

	local buildListData = function()	--将List数据编译为字符串
		local c = #listData
		if c > 0 then
			local text = {}
			for i=1, #listData do
				buildListDataOne(text, listData[i])
			end
			listData = {}
			text = table.concat(text, '')
			
			if listIn == 1 then
				local r = #funcData.returns
				if r > 0 then
					r = funcData.returns[r]
					r.desc = r.desc .. text
				end
			elseif listIn == 2 then
				local p = funcData.params[#funcData.params]
				p.desc = p.desc .. text
			elseif listIn == 3 then
				funcData.desc = funcData.desc .. text
			elseif listIn == 9 then
				staticText = staticText .. text
			end
		end
		
		listIn, listLevel = 0, 0
	end
	
	local checkIsListOrder = function(line) --检查是否是list或order指令，如果是，则判断其缩进级别
		local lv = 1
		local linef = string.trim(line, true, false)

		while string.at(line, lv) == ' ' do
			lv = lv + 1
		end
		if lv > listLevel and lv - listLevel > 1 then
			error(string.format("file '%s' have error syntax in %u line, invalid list/order indient level", filename, lineCount))
		end
		
		if string.cmp(linef, 'list ', 5) then
			return 1, lv, string.sub(line, 5 + lv)
		elseif string.cmp(linef, 'order ', 6) then
			return 2, lv, string.sub(line, 6 + lv)
		end
		return 0
	end

	local saveFuncData = function()	--将当前处理的函数保存起来——如果有的话
		if moduleData and funcData then
			buildListData()
			
			funcData.module = moduleData
			moduleData.indices[funcData.name] = funcData			
			table.insert(moduleData.funcs, funcData)
			funcData = nil
		else
			listData = {}
		end
				
		continueLineFunc = nil
	end
	local saveModuleData = function()	--将当前处理的模块保存起来——如果有的话，如果同名的模块已经存在则自动合并
		if moduleData then
			if docData then
				moduleData.withDoc = docData
			end
			
			local mod = AllModules[moduleData.name]
			if not mod then
				--新增
				AllModules[moduleData.name] = moduleData
			else
				--合并
				for i = 1, #moduleData.funcs do
					table.insert(mod.funcs, moduleData.funcs[i])
				end
				for i = 1, #moduleData.statics do
					table.insert(mod.statics, moduleData.statics[i])
				end
				for name,v in pairs(moduleData.indices) do
					mod.indices[name] = v
				end
			end

			moduleData = nil
		end
	end
	local saveDocData = function(forceSave)
		buildListData()
		
		if docData and staticText ~= nil and (scanMode == 'doc' or forceSave == true) then
			table.insert(docData.segments, staticText)
			continueLineFunc = nil
			staticText = nil
		end
	end
	local saveMenuData = function()		
		if menuData then
			menuData.nodeStack = nil
			AllMenus[#AllMenus + 1] = menuData
			menuData = nil
		end
	end
	
	--各种续接行内容处理函数
	local continueLineCheck = function(line, func)
		local cnt = #line
		if cnt > 0 and string.at(line, cnt) == '\\' then
			if func then 
				continueLineFunc = func
			end
			return string.sub(line, 1, -2)
		end

		continueLineFunc = nil
		return line
	end
	
	local appendToLastListItem = function(line)
		local items = listData[#listData].items
		items = items[#items]
		items.text = items.text .. line
	end
	
	local continueLineR = function(line)
		local cnt = #funcData.returns
		
		if cnt > 0 then
			local r = funcData.returns[cnt]
			r.desc = string.sub(r.desc, 1, -1) .. continueLineCheck(line)
		else
			error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
		end
	end
	local continueLineP = function(line)
		local cnt = #funcData.params

		if cnt > 0 then
			local p = funcData.params[cnt]
			p.desc = string.sub(p.desc, 1, -1) .. continueLineCheck(line)
		else
			error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
		end
	end
	local continueLineD = function(line)
		funcData.desc = string.sub(funcData.desc, 1, -1) .. continueLineCheck(line)
	end
	local continueLineList = function(line)
		appendToLastListItem(continueLineCheck(line))
	end
	local continueStaticText = function(line)
		staticText = staticText .. continueLineCheck(line)
	end
	local continueStaticText2 = function(line)
		staticText = staticText .. continueLineCheck(line, continueStaticText2)
	end
	
	--检查返回值的类型定义是否有问题
	local checkFuncReturnType = function(r)
		local ok = true
		string.split(r[1], '|', function(n, t)
			if AllVarTypes[t] > 0 then return true end
			ok = false
			return ok
		end)
		
		if ok then
			funcData.returns[#funcData.returns + 1] = { type = r[1], desc = continueLineCheck(r[2], continueLineR) }
		end
		
		return ok
	end
	--将参数拆分出来，同时检查定义是否有问题
	local explodeFuncParams = function(p)
		local name, tp = string.cut(p[1], ':')
		string.split(tp, '|', function(n, t)
			if AllVarTypes[t] >= 0 then return true end
			name = nil
			return false
		end)
		if not name then return false end
		
		table.insert(funcData.params, { name = name, type = tp, desc = continueLineCheck(p[2], continueLineP) })
		return true
	end

	
	--逐行处理
	for sourceLine in io.lines(filename) do
		local line = string.trim(sourceLine)
		lineCount = lineCount + 1

		if inComment then
			if line == '--comment end' then
				inComment = false
			end
			goto skipline
		end
		if line == '--comment begin' then
			inComment = true
			goto skipline
		end
		
		if collectSamples > 0 then
			--收集api段中函数说明里的示例代码
			if line == '--]]' then
				collectSamples = 0
				funcData.samplesIndient = nil
			else
				local slen = #funcData.samples
				if not funcData.samplesIndient then
					funcData.samplesIndient = RegExp.find('^([ \\t]*)', slen > 0 and funcData.samples or sourceLine)
				end
				if slen > 0 then
					funcData.samples = funcData.samples .. '\n'
				end
				funcData.samples = funcData.samples .. string.sub(sourceLine, #funcData.samplesIndient + 1)
			end

			goto skipline
		end

		if string.cmp(sourceLine, '--@type:', 8) then
			--这是--@type:这种指令，判断是否合法的指令
			saveFuncData()
			saveModuleData()

			scanMode = AllScanModes[string.sub(line, 9)]
			if scanMode == nil then
				error(string.format("file '%s' have error mode command '%s' in %u line", filename, string.sub(line, 7), lineCount))
			end
			
			if docData then
				saveDocData(true)
				--docData = nil
				
			elseif scanMode == 'doc' then
				docData = { segments={}, samples={} }
			end
			
			continueLineFunc = nil
			staticText = nil	
			goto skipline
		end			
		
		local line1, line2 = string.byte(line, 1, 2)
		if scanMode == 'api' then
			--按api文档的格式对内容进行处理
			if line1 == minus and line2 == minus then
				--以--号开头的是指令或说明
				line = string.sub(line, 3)
				if continueLineFunc then
					--本行为续接的上一行
					if line == 'endl' then
						--强制换行
						continueLineFunc('<br/>\\')
					else
						continueLineFunc(line)
					end

				else
					--其它可以续接行的指令
					if string.cmp(line, 'r ', 2) then
						--返回值
						local r = RegExp.find('^r[\\s]+([\\w|]+)(.*)', line, true)
						if not r or #r ~= 2 or not checkFuncReturnType(r) then
							error(string.format("file '%s' have error syntax in %u line with '--r' command", filename, lineCount))
						end

						buildListData()
						listIn, listLevel = 1, 0
						
					elseif string.cmp(line, 'p ', 2) then
						--参数
						local p = RegExp.find('^p[\\s]+([\\w|\\:\\.]+)(.*)', line, true)
						if not p or #p ~= 2 or not explodeFuncParams(p) then
							error(string.format("file '%s' have error syntax in %u line with '--p' command", filename, lineCount))
						end
						
						buildListData()
						listIn, listLevel = 2, 0

					elseif string.cmp(line, 'title ', 6) then
						funcData.title = string.sub(line, 7);
						
					elseif string.cmp(line, 'group ', 6) then
						--分组的组名
						if funcData then
							error(string.format("file '%s' have error syntax in %u line with '--group' command, cannot use it between function definition", filename, lineCount))
						end
						
					elseif string.cmp(line, 'groupend', 8) then
						--分组结束
						
					elseif string.cmp(line, "[[samples", 9) then
						--示例代码开始
						collectSamples = lineCount
						funcData.samples = #line > 10 and string.sub(line, 10) or ''
						
					elseif string.cmp(line, '-', 1) then
						--3个连续的-号发起的注释，这样的注释不需要\连接多行
						buildListData()
						
						funcData.desc = funcData.desc .. string.sub(line, 2)
						listIn, listLevel = 3, 0
					
					elseif listIn ~= 0 then
						--list/order指令
						local ltp, lv, text = checkIsListOrder(line)
						if ltp == 0 then
							error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
						end
						
						text = continueLineCheck(text, continueLineList)

						if lv > listLevel then
							--如果层次增加，则产生新的list
							local newlv = { tag = (ltp == 1 and 'ul' or 'ol'), items = { { text=text, child=nil } } }
							if #listData == 0 or listCurType == 0 then
								table.insert(listData, newlv)
							else
								local findlv = lv
								local lastItems = listData[#listData].items
								while findlv > 2 do
									findlv = findlv - 1
									lastItems = lastItems[#lastItems].child.items
								end
								lastItems[#lastItems].child = newlv
							end
						else
							--否则，找到上一个list将本条追加到最后
							local findlv = lv
							local lastItems = listData[#listData].items
							while findlv > 1 do
								findlv = findlv - 1
								lastItems = lastItems[#lastItems].child.items
							end
							table.insert(lastItems, { text=text, child=nil })
						end
						
						listCurType, listLevel = ltp, lv
					
					elseif not funcData and moduleData then
						--如果不在函数里但在module下，那么这就是属性或静态值的说明
						listIn, listLevel = 9, 0
						if staticText == nil then
							staticText = continueLineCheck(line, continueStaticText)
						else
							error(string.format("file '%s' have error syntax in %u line : %s", filename, lineCount, line))
						end
						
					else
						error(string.format("file '%s' have error syntax in %u line : %s", filename, lineCount, line))
					end
				end

			elseif string.cmp(line, 'module(', 7) then
				--module指定模块名称
				moduleData = { sourceFilename = filename}
				if line == 'module()' then
					--全局模块没有模块名称
					moduleData.name = ''
				else
					moduleData.name = RegExp.find("^module[\\s]*\\('([\\w]+)'\\)$", line)
					if moduleData.name == nil then
						error(string.format("file '%s' have error syntax in %u line with module define", filename, lineCount))
					end
				end
				
				moduleData.funcs = {}
				moduleData.statics = {}
				moduleData.indices = {}
				moduleData.properties = {}
				
			elseif string.cmp(line, 'function ', 9) then
				--function指定函数开始
				if staticText ~= nil then
					error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
				end
				if not moduleData then
					error(string.format("file '%s' have error syntax in %u line with function defined out of module", filename, lineCount))
				end
				
				if not funcData then
					funcData = { params = {}, returns = {}, desc = '' }
					funcData.name = RegExp.find("^function ([\\w]+)[\\s]*\\(", line)
					if funcData.name == nil then
						error(string.format("file '%s' have error syntax in %u line with function define", filename, lineCount))
					end
					
					funcData.decls, funcData.typedecl = fetchFuncParams(line)
				else
					--一个函数多个不同的定义
					local name = RegExp.find("^function ([\\w]+)[\\s]*\\(", line)
					if name == nil or funcData.name ~= name then
						error(string.format("file '%s' have error syntax in %u line with polymorphic function but diferent name", filename, lineCount))
					end
					
					if type(funcData.decls) == 'string' then
						funcData.decls = { funcData.decls }
					end
					funcData.decls[#funcData.decls + 1] = fetchFuncParams(line)
				end
				
			elseif line == 'end' then
				--end指定函数结束
				saveFuncData()
				
			elseif #line > 0 and not funcData and moduleData then
				--静态成员或属性的定义
				local obj = nil
				local name, value, nameprop = '', nil, nil
				local eqPos = string.find(line, '=', 1, true)
				if eqPos ~= nil then
					--有等于号赋值的
					name = string.trim(string.sub(line, 1, eqPos - 1))
					value = string.trim(string.sub(line, eqPos + 1))
				else
					--无赋值
					name = string.trim(line)
				end
				
				buildListData()

				nameprop = string.split(name, ':')
				if #nameprop == 2 then					
					if AllPropertyAbilities[nameprop[2]] then
						--属性
						name = nameprop[1]
						obj = { name = name, value = value, ability = nameprop[2], text = staticText }
						table.insert(moduleData.properties, obj)
					else
						--带常量值类型说明的静态值
						obj = { name = nameprop[1], value = value, type = nameprop[2], text = staticText }
						table.insert(moduleData.statics, obj)
					end
				else
					--静态值
					obj = { name = name, value = value, text = staticText }
					table.insert(moduleData.statics, obj)
				end
				moduleData.indices[name] = obj

				staticText = nil
				listIn, listLevel = 0, 0
				
			elseif #line > 0 then
				--错误的内容行
				error(string.format("file '%s' have invalid command in %u line", filename, lineCount))
			end
			
		elseif scanMode == 'doc' and docData then
			--按doc文档中的内容进行处理
			if samplesBegin == true then
				if string.cmp(line, "--]]") then
					--注释保存
					if #staticText > 0 then						
						assert(type(staticText) == 'table')
						
						local idx = #docData.segments + 1
						docData.segments[idx] = table.concat(staticText, '\n')
						docData.samples[idx] = true
						staticText = nil
					end
					samplesBegin = false

				elseif #line > 0 then
					staticText[#staticText + 1] = sourceLine
				end
				
			elseif line1 == minus and line2 == minus then
				line = string.sub(line, 3)

				if string.cmp(line, "title ", 6) then
					--文档/段落标题
					if docData.title == nil then
						docData.title = line:sub(7)
					else
						error(string.format("file '%s' have error syntax in %u line with --title", filename, lineCount))
					end
					
				elseif string.cmp(line, "name ", 5) then
					if docData.name == nil then
						docData.name = line:sub(5):trim()
						if AllDocs[docData.name] then
							error(string.format("file '%s' have a document named '%s' is exists", filename, docData.name))
						else
							docData.sourceFilename = filename
							AllDocs[docData.name] = docData							
						end
					else
						error(string.format("file '%s' have error syntax in %u line with --name", filename, lineCount))
					end

				elseif string.cmp(line, "segment ", 8) then
					--段落开始
					saveDocData()

					listIn, listLevel = 9, 0
					if staticText == nil then
						staticText = continueLineCheck(string.sub(line, 8), continueStaticText2)
						if staticText == nil then
							staticText = ''
						end
					else
						error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
					end

				elseif line == "[[" then
					--范例代码开始，于是需要分一个新的段
					if not samplesBegin then
						saveDocData()

						staticText = {}
						samplesBegin = true
					end
					
				elseif continueLineFunc then
					assert(staticText)
					continueStaticText2(line)

				elseif string.byte(line, 1) == minus then
					staticText = staticText .. string.sub(line, 2)
				
				elseif listIn ~= 0 then
					--list/order指令
					local ltp, lv, text = checkIsListOrder(line)
					if ltp == 0 then
						error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
					end

					text = continueLineCheck(text, continueLineList)

					if lv > listLevel then
						--如果层次增加，则产生新的list
						local newlv = { tag = (ltp == 1 and 'ul' or 'ol'), items = { { text=text, child=nil } } }
						if #listData == 0 or listCurType == 0 then
							table.insert(listData, newlv)
						else
							local findlv = lv
							local lastItems = listData[#listData].items
							while findlv > 2 do
								findlv = findlv - 1
								lastItems = lastItems[#lastItems].child.items
							end
							lastItems[#lastItems].child = newlv
						end
					else
						--否则，找到上一个list将本条追加到最后
						local findlv = lv
						local lastItems = listData[#listData].items
						while findlv > 1 do
							findlv = findlv - 1
							lastItems = lastItems[#lastItems].child.items
						end
						table.insert(lastItems, { text=text, child=nil })
					end
					
					listCurType, listLevel = ltp, lv
					
				else
					error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
				end			

			elseif #line > 0 then
				error(string.format("file '%s' have error syntax in %u line", filename, lineCount))
			end
			
		elseif scanMode == 'menu' then
			--按menu定义进行处理。先数前面有多少个\t或空格，就是多少级节点
			if menuData == nil then
				menuData = { childs = {}, sourceFilename = filename }
			end
			
			local lv = 1
			for i = 1, #sourceLine do
				if string.byte(sourceLine, i) <= 32 then
					lv = lv + 1
				else
					break
				end
			end
			
			if line1 == minus and line2 == minus then
				line = string.sub(line, 3)

				if string.cmp(line, "node ", 5) then
					local pnode, node = nil, {}
					
					line = string.sub(line, 6)
					local name = line:match("([A-Za-z0-9\\_.]+)")

					--处理层级的缩进
					pnode = menuData
					for i = 2, lv do
						pnode = pnode.childs[#pnode.childs]
					end

					if name ~= nil and string.byte(line, #name + 1) <= 32 then
						--终极节点
						node.link = name
						node.title = string.trim(string.sub(line, #name + 1))
					else
						--匹配链接名称失败，这说明这是一个父级节点，其下会有子节点
						node.title = line
					end

					if pnode.childs then
						pnode.childs[#pnode.childs + 1] = node						
					else						
						pnode.childs = { node }
					end
				end
			else
			end
					
		else
			print(string.format("file '%s' have unknown character(s) in %u line", filename, lineCount))
			return false
		end

::skipline::
	end

	if collectSamples > 0 then
		error(string.format("file '%s' have error command '--[[samples' begin at %u line and not closed", filename, collectSamples))
	end

	saveDocData()
	saveFuncData()
	saveModuleData()
	saveMenuData()

	AllScanFiles = AllScanFiles + 1
	return true
end

function scanPath(path)
	if fd.pathIsDir(path) then
		if string.sub(path, #path) ~= '/' then
			path = path .. '/'
		end

		local reader = fd.openDir(path)
		while reader:pick() do
			local fname = reader:fullname()
			if fd.pathIsDir(fname) then
				if not scanPath(fname) then
					return false
				end
			elseif fd.pathIsFile(fname) and fd.pathinfo(fname).ext == 'lua' then
				if not scanFile(fname) then
					return false
				end
			end
		end
		reader:close()

	elseif fd.pathIsFile(path) then
		if not scanFile(path) then
			return false
		end
	end
	
	return true
end