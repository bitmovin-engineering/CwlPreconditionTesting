//
//  CwlCatchBadInstruction-PosixAlternative.swift
//  CwlPreconditionTesting
//
//  Created by Matt Gallagher on 8/02/2016.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//

import Foundation

// ALTERNATIVE TO MACH EXCEPTIONS AND OBJECTIVE-C RUNTIME:
// Use a SIGILL signal action and setenv/longjmp/
//
// WARNING:
// This code is quick and dirty. It's a proof of concept for using a SIGILL handler and setjmp/longjmp where Mach exceptions and the Obj-C runtime aren't available. I ran the automated tests when I first wrote this code but I don't personally use it at all so by the time you're reading this comment, it probably broke and I didn't notice.
// Obvious limitations:
//	* It doesn't work when debugging with lldb.
//	* It doesn't scope correctly to the thread (it's global)
//  * In violation of rules for signal handlers, it writes to the "red zone" on the stack
//	* It isn't re-entrant
//  * Plus all of the same caveats as the Mach exceptions version (doesn't play well with other handlers, probably leaks ARC memory, etc)
// Treat it like a loaded shotgun. Don't point it at your face.

private var env = jmp_buf(0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0)

private func triggerLongJmp() {
	longjmp(&env.0, 1)
}

private func sigIllHandler(code: Int32, info: UnsafeMutablePointer<__siginfo>, uap: UnsafeMutablePointer<Void>) -> Void {
	let context = UnsafeMutablePointer<ucontext64_t>(uap)

	// 1. Decrement the stack pointer
	context.memory.uc_mcontext64.memory.__ss.__rsp -= __uint64_t(sizeof(Int))

	// 2. Save the old Instruction Pointer to the stack.
	let rsp = context.memory.uc_mcontext64.memory.__ss.__rsp
	UnsafeMutablePointer<__uint64_t>(bitPattern: UInt(rsp)).memory = rsp

	// 3. Set the Instruction Pointer to the new function's address
	var f: @convention(c) () -> Void = triggerLongJmp
	withUnsafePointer(&f) { context.memory.uc_mcontext64.memory.__ss.__rip = UnsafePointer<__uint64_t>($0).memory }
}

/// Without Mach exceptions or the Objective-C runtime, there's nothing to put in the exception object. It's really just a boolean – either a SIGILL was caught or not.
public class BadInstructionException {
}

/// Run the provided block. If a POSIX SIGILL is received, handle it and return a BadInstructionException (which is just an empty object in this POSIX signal version). Otherwise return nil.
/// NOTE: This function is only intended for use in test harnesses – use in a distributed build is almost certainly a bad choice. If a SIGILL is received, the block will be interrupted using a C `longjmp`. The risks associated with abrupt jumps apply here: most Swift functions are *not* interrupt-safe. Memory may be leaked and the program will not necessarily be left in a safe state.
public func catchBadInstruction(block: () -> Void) -> BadInstructionException? {
	// Construct the signal action
	var sigActionPrev = sigaction()
	let action = __sigaction_u(__sa_sigaction: sigIllHandler)
	var sigActionNew = sigaction(__sigaction_u: action, sa_mask: sigset_t(), sa_flags: SA_SIGINFO)
	
	// Install the signal action
	if sigaction(SIGILL, &sigActionNew, &sigActionPrev) != 0 {
		fatalError("Sigaction error: \(errno)")
	}

	defer {
		// Restore the previous signal action
		if sigaction(SIGILL, &sigActionPrev, nil) != 0 {
			fatalError("Sigaction error: \(errno)")
		}
	}

	// Prepare the jump point
	if setjmp(&env.0) != 0 {
		// Handle jump received
		return BadInstructionException()
	}

	// Run the block
	block()
	
	return nil
}