---
layout: post
title: "CQRS Asynchronous Error Management"
date: 2015-10-30 12:00:00
categories: CQRS
excerpt: >
  How do you warn your user when a command failed when your command handler is async?
---
So, I've got a design problem.

I've got an aggregate that throws domain exceptions when *valid* commands break invariants. Yes, it can happen (because of an UI out of sync when a command is sent for example).

Problem is, if my handler is asynchronous, the command would just be rejected (as it should), but I have no way to warn the user who issued the failing command. And **I WANT** him to be notified if it fails.

Of course, the easy way would be to say "If you really need your user to be notified right away, juste make your handler synchronous and you won't have a problem anymore"... well, that's true, but let's pretend that, for various reasons, **I NEED** it to be asynchronous.

So I've looked it up on google and found some interesting stuff about it. First, there's this [question asked](https://groups.google.com/forum/#!topic/dddcqrs/Qd5afPyX6e8), and especially some of the answers which lead me to this [article](http://thinkbeforecoding.com/post/2009/12/10/Business-Errors-are-Just-Ordinary-Events), and bottom-line is *"Why bother and don't treat error cases like just any other event?"*.

And yeah, why the fuck not? It sure is pretty tempting.

Well, because exceptions are great when you're talking about preventing to alter your domain and reject the command. That's what they've been created for. Also, why the hell would I want to emit an event that won't modify my aggregate (and store it if it's event sourced)?

And what if, before breaking invariants, my command has already emitted another event which would have modified my aggregate. I certainly don't want that (I mean, you could want that, but if you don't, it really sucks).

So, what should I do? Forget about exceptions and emit those domain error events and manage the eventual side effects OR find another way to do it?

Of course, I'll try to do it the other way, but what would this other way could be? Because, as you know, there aren't a lot of options here. Your events **HAVE TO** be emitted within the scope of the command handler, not anywhere else.

So what if you could have exceptions (which would interrupt your command) **AND** domain error events? How great would it be?

So, to sum it up the situation, we've got our command handler which will get the aggregate through its repository, make the domain action described by the command, and finally, the repository saving the modified aggregate and emitting the events outside through its embedded event bus. And, around it, of course, our exception management structure.

    public function handleFooCommand(FooCommand $command)
    {
        try {
            $domainObject = $this->domainObjectRepository->load($command->getAggregateId());
            $domainObject->foo(); // throws the domain exception
            $this->domainObjectRepository->save($domainObject); // saves the aggregate and emits the events
        } catch (DomainException $e) {
            // handle domain exception and notify the world
        } catch (Exception $e) {
            // handle exception (and notify the world?)
        }
    }

Given that, if we want to notify the outside world the command failed, as the save method of the repository wasn't reached, we'll have to emit the "error" event here. Doing so, you will be emitting events from two different layers, and that's something you don't really want to do either.

    public function handleFooCommand(FooCommand $command)
    {
        try {
            ...
        } catch (DomainException $e) {
            $this->eventBus->emit(new DomainErrorEvent(...));
        } catch (Exception $e) {
            ...
        }
    }

So, what would the solution be?