/*
 * screenlock_integration.cpp
 * 
 * Copyright 2025 Daniel Kondor <kondor.dani@gmail.com>
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * 
 */


#include <wayfire/plugin.hpp>
#include <wayfire/core.hpp>
#include <wayfire/option-wrapper.hpp>
#include <wayfire/config/types.hpp>
#include <wayfire/bindings-repository.hpp>
#include "../config.h"

class screenlock_integration : public wf::plugin_interface_t
{
private:
	
	wf::key_callback lock = [] (auto)
	{
		wf::get_core ().run ("loginctl lock-session");
		return true;
	};
	
public:
	void init () override
	{
		wf::get_core ().bindings->add_key (wf::option_wrapper_t<wf::keybinding_t>{"screenlock_integration/lock"}, &lock);
		wf::get_core ().run (PROXY_BINARY);
	}
	
	void fini () override
	{
		wf::get_core ().bindings->rem_binding (&lock);
	}
	
	bool is_unloadable () override
	{
		return false;
	}
};

DECLARE_WAYFIRE_PLUGIN(screenlock_integration);
