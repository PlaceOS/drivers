# Runtime Debugging

This is supported via VS Code on OSX or Linux platforms.
It might be possible to do remote debugging on Windows in conjunction with the Linux Layer.

* Requires [VS Code](https://code.visualstudio.com/)
  * install [Crystal Lang](https://marketplace.visualstudio.com/items?itemName=faustinoaq.crystal-lang) extension
  * install [Native Debug](https://marketplace.visualstudio.com/items?itemName=webfreak.debug) extension
* Requires [GDB](https://www.gnu.org/software/gdb/)
  * On OSX install using [Homebrew](https://brew.sh/)
  * Then code sign the executable: https://sourceware.org/gdb/wiki/PermissionsDarwin
    * The `gdb-entitlement.xml` file is in this folder
    * When creating the signing certificate follow [this guide](https://apple.stackexchange.com/questions/309017/unknown-error-2-147-414-007-on-creating-certificate-with-certificate-assist)

This should also work with [LLDB](https://lldb.llvm.org/) on OSX however [has issues](https://github.com/crystal-lang/crystal/issues/4457).


## Debug on VSCode

By convention the project directory name is the same as your application name, if you have changed it, please update `${workspaceFolderBasename}` with the name configured inside `shards.yml`

### 1. `tasks.json` configuration to compile a crystal project

```javascript
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Compile",
      "command": "shards build --debug ${workspaceFolderBasename}",
      "type": "shell"
    }
  ]
}
```

### 2. `launch.json` configuration to debug a binary

#### Using GDB

```javascript
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug",
      "type": "gdb",
      "request": "launch",
      "target": "./bin/${workspaceFolderBasename}",
      "cwd": "${workspaceRoot}",
      "preLaunchTask": "Compile"
    }
  ]
}
```

#### Using LLDB

```javascript
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug",
      "type": "lldb-mi",
      "request": "launch",
      "target": "./bin/${workspaceFolderBasename}",
      "cwd": "${workspaceRoot}",
      "preLaunchTask": "Compile"
    }
  ]
}
```

### 3. Then hit the DEBUG green play button

![debugging](https://i.imgur.com/GsGT1h0.png)

## Tips and Tricks for debugging Crystal applications

### 1. Use debugger keyword

Instead of putting breakpoints using commands inside GDB or LLDB you can try to set a breakpoint using `debugger` keyword.

```ruby
i = 0
while i < 3
  i += 1
  debugger # => breakpoint
end
```

### 2. Avoid breakpoints inside blocks

Currently, Crystal lacks support for debugging inside of blocks. If you put a breakpoint inside a block, it will be ignored.

As a workaround, use `pp` to pretty print objects inside of blocks.

```ruby
3.times do |i|
  pp i
end
# i => 1
# i => 2
# i => 3
```

### 3. Try `@[NoInline]` to debug arguments data

Sometimes crystal will optimize argument data, so the debugger will show `<optimized output>` instead of the arguments. To avoid this behavior use the `@[NoInline]` attribute before your function implementation.

```ruby
@[NoInline]
def foo(bar)
  debugger
end
```

### 4. Printing strings objects \(GDB\)

To print string objects in the debugger:

First, setup the debugger with the `debugger` statement:

```ruby
foo = "Hello World!"
debugger
```

Then use `print` in the debugging console.

```bash
(gdb) print &foo.c
$1 = (UInt8 *) 0x10008e6c4 "Hello World!"
```

Or add `&foo.c` using a new variable entry on watch section in VSCode debugger

![Using VSCode GUI](https://i.imgur.com/EpQinL7.png)

### 5. Printing array variables

To print array items in the debugger:

First, setup the debugger with the `debugger` statement:

```ruby
foo = ["item 0", "item 1", "item 2"]
debugger
```

Then use `print` in the debugging console:

```bash
(gdb) print &foo.buffer[0].c
$19 = (UInt8 *) 0x10008e7f4 "item 0"
```

Change the buffer index for each item you want to print.

### 6. Printing instance variables

For printing `@foo` var in this code:

```ruby
class Bar
  @foo = 0
  def baz
    debugger
  end
end

Bar.new
```

You can use `self.foo` in the debugger terminal or VSCode GUI.

### 7. Print hidden objects

Some objects do not show at all. You can unhide them using the `.to_s` method and a temporary debugging variable, like this:

```ruby
def bar(hello)
  "#{hello} World!"
end

def foo(hello)
  bar_hello_to_s = bar(hello).to_s
  debugger
end

foo("Hello")
```

This trick allows showing the `bar_hello_to_s` variable inside the debugger tool.
